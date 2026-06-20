defmodule Predictex.Results.Ingest do
  @moduledoc """
  Ingest openfootball results into the database, idempotently.

  Gather → Decide → Act:

    * **Gather** — `sync_from_url/1` / `sync_from_file/1` read the JSON (the only I/O).
    * **Decide** — `plan/1` is pure: parse the feed, map fixtures to FIFA rounds, and
      build the round + fixture attribute maps.
    * **Act** — `commit/1` upserts rounds (by ordinal) and fixtures (knockout fixtures by their
      stable openfootball `source_num`, group fixtures by `external_ref` — see `find_fixture/1`).

  Re-running is safe and idempotent. The update casts only the parsed result fields, which never
  include `cohort_*_pct`, so **admin-entered cohort %s and a round's open state are preserved**.
  Keying knockout fixtures on `source_num` lets their teams resolve in place when the bracket
  settles, instead of the changed `external_ref` spawning a duplicate fixture (predictex-g8m).
  """

  alias Predictex.Repo
  alias Predictex.Results.Openfootball
  alias Predictex.Fifa
  alias Predictex.Tournament
  alias Predictex.Tournament.{Fixture, Round}

  @default_url "https://raw.githubusercontent.com/openfootball/worldcup.json/master/2026/worldcup.json"

  # --- Gather ---

  def sync_from_url(url \\ @default_url) do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get(url, decode_body: false, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} -> body |> Jason.decode!() |> sync()
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `path` is a trusted local/admin file (seeds + ops fixtures), never user input — the
  # File.read! directory-traversal finding is accepted. Inline skip (replaces the former
  # .sobelow-skips fingerprint, which drifted whenever an edit above this line moved it).
  # sobelow_skip ["Traversal.FileModule"]
  def sync_from_file(path), do: path |> File.read!() |> Jason.decode!() |> sync()

  def sync(doc) when is_map(doc), do: doc |> plan() |> commit()

  # --- Decide (pure) ---

  @doc "Build the round and fixture upsert plan from a decoded openfootball document."
  def plan(doc) when is_map(doc) do
    fixtures = doc |> Openfootball.parse() |> Fifa.assign_rounds()

    rounds =
      fixtures
      |> Enum.map(& &1.game_round)
      |> Enum.reject(&is_nil(&1.ordinal))
      |> Enum.uniq_by(& &1.ordinal)
      |> Enum.map(&%{ordinal: &1.ordinal, name: &1.name, stage: &1.stage})

    fixture_plans = Enum.map(fixtures, &fixture_plan/1)

    %{rounds: rounds, fixtures: fixture_plans}
  end

  defp fixture_plan(fixture) do
    %{
      ordinal: fixture.game_round.ordinal,
      attrs: %{
        external_ref: fixture.external_ref,
        source_num: fixture.source_num,
        team1: fixture.team1,
        team2: fixture.team2,
        group: fixture.group,
        kickoff_at: fixture.kickoff_at,
        status: fixture.status,
        home_goals: fixture.home_goals,
        away_goals: fixture.away_goals,
        first_scorer_side: fixture.first_scorer_side,
        first_scorer_player: fixture.first_scorer_player,
        first_goal_owngoal: fixture.first_goal_owngoal,
        goals: fixture.goals
      }
    }
  end

  # --- Act ---

  @doc "Apply a plan: upsert rounds then fixtures. Returns a summary map."
  def commit(%{rounds: rounds, fixtures: fixtures}) do
    round_ids = Map.new(rounds, fn r -> {r.ordinal, upsert_round(r).id} end)

    results = Enum.map(fixtures, &upsert_fixture(&1, round_ids))

    # Coarse "fixtures changed" signal so live dashboards re-pull the settle/result without
    # polling (predictex-9p0). One broadcast per sync run — the subscriber's re-pull is
    # idempotent, so per-fixture transition diffing would be wasted work.
    if fixtures != [], do: Tournament.broadcast_change()

    %{
      rounds: map_size(round_ids),
      fixtures_ok: Enum.count(results, &match?({:ok, _}, &1)),
      fixtures_error: Enum.count(results, &match?({:error, _}, &1))
    }
  end

  defp upsert_round(%{ordinal: ordinal} = attrs) do
    case Tournament.get_round_by_ordinal(ordinal) do
      nil ->
        {:ok, round} = Tournament.create_round(attrs)
        round

      %Round{} = existing ->
        existing
    end
  end

  defp upsert_fixture(%{ordinal: ordinal, attrs: attrs}, round_ids) do
    attrs = Map.put(attrs, :round_id, Map.get(round_ids, ordinal))

    # Find-then-write rather than an atomic DB upsert: the identity is dual (source_num for KO,
    # external_ref for group) so there's no single conflict_target. The unique indexes on both
    # columns are the backstop — a concurrent double-insert returns {:error, changeset} (counted
    # in fixtures_error), never a duplicate row. In practice the 15-min ResultSync is single-flight.
    case find_fixture(attrs) do
      nil -> %Fixture{} |> Fixture.changeset(attrs) |> Repo.insert()
      %Fixture{} = existing -> existing |> Fixture.changeset(attrs) |> Repo.update()
    end
  end

  # Fixture identity (predictex-g8m): knockout fixtures by their stable openfootball `source_num`
  # — so when the bracket resolves and the teams (hence external_ref) change, the SAME row is
  # updated rather than a duplicate inserted. Group fixtures, and the first sync that still has to
  # stamp source_num onto a placeholder KO row, fall through to external_ref. A changeset-driven
  # update only casts the parsed attrs (which never include `cohort_*_pct`), so admin-entered
  # cohort %s survive a re-sync untouched — the property the old @replace_on_conflict list guarded.
  defp find_fixture(%{source_num: num, external_ref: ref}) when is_integer(num) do
    Tournament.get_fixture_by_source_num(num) || Tournament.get_fixture_by_ref(ref)
  end

  defp find_fixture(%{external_ref: ref}), do: Tournament.get_fixture_by_ref(ref)
end
