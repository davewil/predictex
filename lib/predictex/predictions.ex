defmodule Predictex.Predictions do
  @moduledoc """
  Context for player predictions.

  `create_prediction/2` follows Gather → Decide → Act: it gathers the fixture (for
  its round and kickoff time), decides whether the fixture has locked at kickoff,
  then acts by inserting. The denormalized `round_id` is always set from the fixture,
  so it cannot drift.
  """
  import Ecto.Query, warn: false

  alias Predictex.Repo
  alias Predictex.Predictions.SavedPrediction
  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture
  alias Predictex.Scoring.Knockout

  def list_predictions, do: Repo.all(SavedPrediction)

  @doc "All of one player's predictions (any round, any fixture state)."
  def list_player_predictions(player_id) do
    Repo.all(from p in SavedPrediction, where: p.player_id == ^player_id)
  end

  def change_prediction(%SavedPrediction{} = prediction \\ %SavedPrediction{}, attrs \\ %{}) do
    SavedPrediction.changeset(prediction, attrs)
  end

  @doc """
  Create a prediction for a fixture.

  Returns `{:ok, prediction}`, `{:error, changeset}` on validation/constraint
  failure, `{:error, :locked}` if the fixture has kicked off, or
  `{:error, :fixture_not_found}` for an unknown fixture.
  """
  def create_prediction(attrs, now \\ DateTime.utc_now()) do
    with {:ok, fixture} <- fetch_fixture(attrs),
         :ok <- ensure_open(fixture, now) do
      attrs
      |> Map.put(:round_id, fixture.round_id)
      |> Map.put(:fixture_id, fixture.id)
      |> then(&SavedPrediction.changeset(%SavedPrediction{}, &1))
      |> Repo.insert()
    end
    |> broadcast_on_success()
  end

  @doc """
  Insert-or-update a prediction on behalf of a player (admin path).

  Unlike `create_prediction/2`, this does **not** check the kickoff lockout — the
  admin transcribes screenshots after the fact, and the screenshot is the proof the
  player picked in time. Keyed on `{player_id, fixture_id}`. Runs in a transaction:
  if the row sets `booster: true`, any other booster for the player in that round is
  cleared first, so moving a booster cannot trip the non-deferrable
  `one_booster_per_player_round` unique index.

  Returns `{:ok, prediction}`, `{:error, changeset}`, or `{:error, :fixture_not_found}`.
  """
  def admin_upsert_prediction(attrs) do
    case fetch_fixture(attrs) do
      {:ok, fixture} ->
        player_id = take(attrs, :player_id)

        attrs =
          attrs
          |> Map.put(:round_id, fixture.round_id)
          |> Map.put(:fixture_id, fixture.id)

        Repo.transaction(fn ->
          if booster_set?(attrs) do
            clear_round_booster(player_id, fixture.round_id, fixture.id)
          end

          existing = Repo.get_by(SavedPrediction, player_id: player_id, fixture_id: fixture.id)

          case Repo.insert_or_update(
                 SavedPrediction.changeset(existing || %SavedPrediction{}, attrs)
               ) do
            {:ok, pred} -> pred
            {:error, cs} -> Repo.rollback(cs)
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
    |> broadcast_on_success()
  end

  @doc """
  Batch-save one player's predictions for a whole round (the by-player "Save all" path).

  Runs in a single transaction: clears every booster for `{player_id, round_id}` first
  (so the radio's single selection cannot collide with the non-deferrable unique index),
  then upserts each row. A row is **skipped** when both goals are nil; **upserted** when
  both are present and valid; reported as `{:error, changeset}` when invalid (e.g. exactly
  one goal). Returns `{:ok, results}` where `results` maps `fixture_id => :upserted | :skipped | {:error, cs}`.

  `{:ok, results}` is returned even when ordinary rows failed validation — callers MUST
  inspect the per-fixture results map; an `{:error, cs}` entry means that row did not
  persist while the others did.

  The one exception is a booster placed on a row with no scoreline: because the round's
  boosters are cleared up front, letting that commit would silently destroy the player's
  existing booster. So the whole save is rolled back and `{:error, {:booster_on_blank,
  results}}` is returned, leaving prior state untouched.
  """
  def admin_save_round_predictions(player_id, round_id, rows) when is_list(rows) do
    Repo.transaction(fn ->
      from(p in SavedPrediction, where: p.player_id == ^player_id and p.round_id == ^round_id)
      |> Repo.update_all(set: [booster: false])

      results =
        Enum.reduce(rows, %{}, fn row, acc ->
          Map.put(acc, row.fixture_id, save_round_row(player_id, round_id, row))
        end)

      if Enum.any?(results, fn {_id, r} -> r == {:error, :booster_on_blank} end) do
        Repo.rollback({:booster_on_blank, results})
      else
        results
      end
    end)
    |> broadcast_on_success()
  end

  @doc """
  Member-facing round save (the lockout-aware sibling of `admin_save_round_predictions/3`).

  Locked fixtures (kickoff passed) are immutable: their rows are not written (result
  `:locked`), and the up-front booster clear only touches unlocked fixtures, so a booster
  already committed to a locked fixture is preserved. Otherwise mirrors the admin path:
  sparse-grid upsert with the booster-on-blank guard.

  **Round-membership enforcement:** rows whose `fixture_id` does not belong to `round_id`
  are rejected outright — result `:unknown`, never written. This is the primary
  write-authorization guard at the trust boundary: a crafted payload cannot write a
  prediction on a fixture from another round or a non-existent fixture. The existing
  `locked?(nil, _now)` defensive clause is now unreachable from this path.
  """
  def save_round_predictions(player_id, round_id, rows, enabled?, now \\ DateTime.utc_now())

  # Write-path feature gate (defense in depth, predictex-5q6): when `:native_ko_entry` is
  # off for the actor, reject before any DB work — a crafted save_round payload can't bypass
  # a dark flag even if the LiveView render guard is removed. The caller resolves the flag;
  # this context stays FunWithFlags-agnostic and unit-testable. Composes with the
  # round-membership + lockout write-auth below.
  def save_round_predictions(_player_id, _round_id, _rows, false, _now),
    do: {:error, :feature_disabled}

  def save_round_predictions(player_id, round_id, rows, true, now)
      when is_list(rows) do
    fixtures = Map.new(Repo.all(from f in Fixture, where: f.round_id == ^round_id), &{&1.id, &1})

    # Commit-at-kickoff booster guard (predictex-80k): if a kicked-off fixture in this round
    # already holds the booster and the submit sets a booster on a different fixture, reject
    # cleanly instead of hitting the one-booster-per-round unique index. The member keeps the
    # committed booster and gets a clear message.
    if booster_locked_conflict?(player_id, round_id, fixtures, rows, now) do
      {:error, :booster_locked}
    else
      do_save_round_predictions(player_id, round_id, rows, fixtures, now)
    end
  end

  defp do_save_round_predictions(player_id, round_id, rows, fixtures, now) do
    # Partition rows by round membership FIRST.
    # Unknown rows (fixture_id not in this round) are rejected immediately as :unknown.
    {known, unknown} = Enum.split_with(rows, &Map.has_key?(fixtures, &1.fixture_id))

    # Among known rows, split by lockout. Map.fetch! is safe — membership is guaranteed above.
    {locked, open} = Enum.split_with(known, &locked?(Map.fetch!(fixtures, &1.fixture_id), now))

    # Among unlocked rows, reject those whose fixture is still a bracket placeholder (:pending):
    # the UI never offers them; a crafted payload is dropped here (defense in depth).
    {pending, editable} =
      Enum.split_with(open, fn row ->
        fx = Map.fetch!(fixtures, row.fixture_id)
        not (Knockout.resolved_team?(fx.team1) and Knockout.resolved_team?(fx.team2))
      end)

    Repo.transaction(fn ->
      editable_ids = Enum.map(editable, & &1.fixture_id)

      # Clear boosters only among the editable (unlocked, resolved) fixtures being (re)saved.
      from(p in SavedPrediction,
        where:
          p.player_id == ^player_id and p.round_id == ^round_id and
            p.fixture_id in ^editable_ids
      )
      |> Repo.update_all(set: [booster: false])

      saved =
        Enum.reduce(editable, %{}, fn row, acc ->
          Map.put(acc, row.fixture_id, save_round_row(player_id, round_id, row))
        end)

      results =
        Enum.reduce(locked, saved, fn row, acc -> Map.put(acc, row.fixture_id, :locked) end)

      results =
        Enum.reduce(pending, results, fn row, acc -> Map.put(acc, row.fixture_id, :pending) end)

      # Mark out-of-round / non-existent fixture ids as :unknown — never written.
      results =
        Enum.reduce(unknown, results, fn row, acc -> Map.put(acc, row.fixture_id, :unknown) end)

      if Enum.any?(results, fn {_id, r} -> r == {:error, :booster_on_blank} end) do
        Repo.rollback({:booster_on_blank, results})
      else
        results
      end
    end)
    |> broadcast_on_success()
  end

  # A different fixture already holds the booster AND it has kicked off → the booster is
  # committed to it for the round; a new booster elsewhere is rejected. Short-circuits when the
  # submit carries no booster (the common case), skipping the committed-booster query (predictex-cfi).
  defp booster_locked_conflict?(player_id, round_id, fixtures, rows, now) do
    case Enum.find(rows, & &1.booster) do
      nil ->
        false

      incoming ->
        committed_id =
          Repo.one(
            from p in SavedPrediction,
              where: p.player_id == ^player_id and p.round_id == ^round_id and p.booster == true,
              select: p.fixture_id
          )

        not is_nil(committed_id) and incoming.fixture_id != committed_id and
          locked?(Map.get(fixtures, committed_id), now)
    end
  end

  @doc "All players' predictions for one fixture, with the player preloaded (by-fixture admin lens)."
  def list_fixture_predictions(fixture_id) do
    from(p in SavedPrediction, where: p.fixture_id == ^fixture_id, preload: [:player])
    |> Repo.all()
  end

  @doc """
  One player's own prediction for one fixture (or `nil`).

  The anti-copy input boundary for the "If your pick lands" card (kcx): it fetches ONLY the
  viewing member's own pick, never the full `list_fixture_predictions/1`, so it is safe to read
  pre-kickoff while everyone else's picks are still hidden.
  """
  def get_player_fixture_prediction(player_id, fixture_id) do
    Repo.one(
      from p in SavedPrediction, where: p.player_id == ^player_id and p.fixture_id == ^fixture_id
    )
  end

  @doc "A fixture is locked for predictions once kickoff has passed."
  def locked?(nil, _now), do: false
  def locked?(%Fixture{kickoff_at: nil}, _now), do: false
  def locked?(%Fixture{kickoff_at: kickoff}, now), do: DateTime.compare(now, kickoff) != :lt

  @doc """
  Per-fixture native KO entry state at `now` (predictex-80k):

    * `:pending`  — a slot is still a bracket placeholder; can't predict an unknown team
    * `:locked`   — both teams resolved, kickoff has passed (read-only)
    * `:editable` — both teams resolved, kickoff in the future

  `:pending` is checked first so an unresolved fixture is never editable even if its scheduled
  kickoff has somehow passed. Reuses `locked?/2` so the lockout rule has one definition.
  """
  def fixture_entry_state(%Fixture{team1: t1, team2: t2} = fixture, now) do
    cond do
      not (Knockout.resolved_team?(t1) and Knockout.resolved_team?(t2)) -> :pending
      locked?(fixture, now) -> :locked
      true -> :editable
    end
  end

  # The live drill-down (FixtureLive) CTA opens this long before kickoff.
  @cta_lead_seconds 30 * 60

  @doc "Seconds before kickoff that the preview / live drill-down CTA window opens."
  def cta_lead_seconds, do: @cta_lead_seconds

  @doc """
  Whether the live drill-down CTA should be offered for a fixture at `now`.

  Open-ended from `@cta_lead_seconds` (30 min) before kickoff onwards: it covers the
  pre-kickoff preview window, the live match, and stays afterwards as a post-match recap
  (predictex-4zu). Pure — the caller supplies `now`.
  """
  def cta_window?(%Fixture{kickoff_at: nil}, _now), do: false

  def cta_window?(%Fixture{kickoff_at: kickoff}, now),
    do: DateTime.compare(now, DateTime.add(kickoff, -@cta_lead_seconds, :second)) != :lt

  @doc """
  Pure prediction-intake boundary: parse raw form params (the `picks` map plus the selected
  `booster_fixture_id`) into validated pick rows.

  Returns `{:ok, [row]}`, each row
  `%{fixture_id, home_goals, away_goals, first_scorer_side, first_scorer_player, booster}`,
  or `{:error, :booster_on_blank}` when a booster sits on a blank scoreline. Blank-goal rows
  are KEPT (the persistence layer decides to `:skip` them); a non-integer fixture key is
  skipped rather than crashing. Pure — no `Repo`. The form LiveViews cross here; the invariant
  itself is owned by `validate_pick_rows/1`.
  """
  def parse_pick_rows(picks, booster_id_param) when is_map(picks) do
    boost_id = parse_int(booster_id_param)

    picks
    |> Enum.flat_map(&parse_row(&1, boost_id))
    |> validate_pick_rows()
  end

  @doc """
  Pure owner of the prediction-intake invariant: a booster requires a scoreline.

  Returns `{:ok, rows}` unchanged, or `{:error, :booster_on_blank}` if any row carries a
  booster on a blank (nil/nil) scoreline. Shared by `parse_pick_rows/2` (the form boundary)
  and FIFA import, so every producer of pick rows is held to the same invariant.
  """
  def validate_pick_rows(rows) when is_list(rows) do
    if Enum.any?(rows, &booster_on_blank?/1),
      do: {:error, :booster_on_blank},
      else: {:ok, rows}
  end

  # --- internals ---

  # A successful prediction write can change the standings (an admin/import write on an
  # already-completed fixture scores immediately, and any pick changes that player's
  # dashboard), so emit the same coarse `:fixtures_changed` signal the result-settle paths
  # use (predictex-9p0) — open `/predictions` sessions re-pull instead of going stale.
  # Coarse by design: over-broadcasting just costs subscribers a cheap re-pull; missing one
  # leaves a stale board. Only `{:ok, _}` writes broadcast — failed/locked writes do not.
  defp broadcast_on_success({:ok, _} = result) do
    Tournament.broadcast_change()
    result
  end

  defp broadcast_on_success(result), do: result

  defp fetch_fixture(attrs) do
    case attrs[:fixture_id] || attrs["fixture_id"] do
      nil ->
        {:error, :fixture_not_found}

      id ->
        case Repo.get(Fixture, id) do
          nil -> {:error, :fixture_not_found}
          fixture -> {:ok, fixture}
        end
    end
  end

  defp ensure_open(fixture, now) do
    if locked?(fixture, now), do: {:error, :locked}, else: :ok
  end

  # Read a key whether the attrs map is atom- or string-keyed.
  defp take(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, val} -> val
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp booster_set?(attrs), do: take(attrs, :booster) in [true, "true"]

  defp clear_round_booster(player_id, round_id, except_fixture_id) do
    from(p in SavedPrediction,
      where:
        p.player_id == ^player_id and p.round_id == ^round_id and
          p.fixture_id != ^except_fixture_id and p.booster == true
    )
    |> Repo.update_all(set: [booster: false])
  end

  defp save_round_row(_player_id, _round_id, %{home_goals: nil, away_goals: nil, booster: true}),
    do: {:error, :booster_on_blank}

  defp save_round_row(_player_id, _round_id, %{home_goals: nil, away_goals: nil}), do: :skipped

  defp save_round_row(player_id, round_id, row) do
    attrs =
      row
      |> Map.put(:player_id, player_id)
      |> Map.put(:round_id, round_id)

    existing = Repo.get_by(SavedPrediction, player_id: player_id, fixture_id: row.fixture_id)

    case Repo.insert_or_update(SavedPrediction.changeset(existing || %SavedPrediction{}, attrs)) do
      {:ok, _pred} -> :upserted
      {:error, cs} -> {:error, cs}
    end
  end

  # --- pure pick-row parsing (the prediction-intake boundary) ---

  defp parse_row({fid, attrs}, boost_id) do
    case parse_int(fid) do
      nil -> []
      fixture_id -> [build_row(fixture_id, attrs, boost_id)]
    end
  end

  defp build_row(fixture_id, attrs, boost_id) do
    %{
      fixture_id: fixture_id,
      home_goals: parse_int(attrs["home_goals"]),
      away_goals: parse_int(attrs["away_goals"]),
      first_scorer_side: parse_side(attrs["first_scorer_side"]),
      first_scorer_player: blank_to_nil(attrs["first_scorer_player"]),
      first_scorer_fifaid: parse_int(attrs["first_scorer_fifaid"]),
      booster: fixture_id == boost_id
    }
  end

  defp booster_on_blank?(%{booster: true, home_goals: nil, away_goals: nil}), do: true
  defp booster_on_blank?(_), do: false

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_side("home"), do: :home
  defp parse_side("away"), do: :away
  defp parse_side(_), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: s
end
