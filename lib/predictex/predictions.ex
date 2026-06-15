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
  alias Predictex.Predictions.Prediction
  alias Predictex.Tournament.Fixture

  def list_predictions, do: Repo.all(Prediction)

  @doc "All of one player's predictions (any round, any fixture state)."
  def list_player_predictions(player_id) do
    Repo.all(from p in Prediction, where: p.player_id == ^player_id)
  end

  def change_prediction(%Prediction{} = prediction \\ %Prediction{}, attrs \\ %{}) do
    Prediction.changeset(prediction, attrs)
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
      |> then(&Prediction.changeset(%Prediction{}, &1))
      |> Repo.insert()
    end
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

          existing = Repo.get_by(Prediction, player_id: player_id, fixture_id: fixture.id)

          case Repo.insert_or_update(Prediction.changeset(existing || %Prediction{}, attrs)) do
            {:ok, pred} -> pred
            {:error, cs} -> Repo.rollback(cs)
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Batch-save one player's predictions for a whole round (the by-player "Save all" path).

  Runs in a single transaction: clears every booster for `{player_id, round_id}` first
  (so the radio's single selection cannot collide with the non-deferrable unique index),
  then upserts each row. A row is **skipped** when both goals are nil; **upserted** when
  both are present and valid; reported as `{:error, changeset}` when invalid (e.g. exactly
  one goal). Returns `{:ok, results}` where `results` maps `fixture_id => :upserted | :skipped | {:error, cs}`.

  `{:ok, results}` is returned even when some rows failed — callers MUST inspect the
  per-fixture results map; an `{:error, cs}` entry means that row did not persist while
  the others did.
  """
  def admin_save_round_predictions(player_id, round_id, rows) when is_list(rows) do
    Repo.transaction(fn ->
      from(p in Prediction, where: p.player_id == ^player_id and p.round_id == ^round_id)
      |> Repo.update_all(set: [booster: false])

      Enum.reduce(rows, %{}, fn row, acc ->
        Map.put(acc, row.fixture_id, save_round_row(player_id, round_id, row))
      end)
    end)
  end

  @doc "All players' predictions for one fixture, with the player preloaded (by-fixture admin lens)."
  def list_fixture_predictions(fixture_id) do
    from(p in Prediction, where: p.fixture_id == ^fixture_id, preload: [:player])
    |> Repo.all()
  end

  @doc "A fixture is locked for predictions once kickoff has passed."
  def locked?(%Fixture{kickoff_at: nil}, _now), do: false
  def locked?(%Fixture{kickoff_at: kickoff}, now), do: DateTime.compare(now, kickoff) != :lt

  # --- internals ---

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
    from(p in Prediction,
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

    existing = Repo.get_by(Prediction, player_id: player_id, fixture_id: row.fixture_id)

    case Repo.insert_or_update(Prediction.changeset(existing || %Prediction{}, attrs)) do
      {:ok, _pred} -> :upserted
      {:error, cs} -> {:error, cs}
    end
  end
end
