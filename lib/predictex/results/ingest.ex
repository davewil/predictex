defmodule Predictex.Results.Ingest do
  @moduledoc """
  Ingest openfootball results into the database, idempotently.

  Gather → Decide → Act:

    * **Gather** — `sync_from_url/1` / `sync_from_file/1` read the JSON (the only I/O).
    * **Decide** — `plan/1` is pure: parse the feed, map fixtures to FIFA rounds, and
      build the round + fixture attribute maps.
    * **Act** — `commit/1` upserts rounds (by ordinal) and fixtures (by `external_ref`).

  Re-running is safe: fixtures are matched on `external_ref` and only result fields
  are replaced on conflict — **admin-entered cohort %s and a round's open state are
  preserved**.
  """

  alias Predictex.Repo
  alias Predictex.Results.Openfootball
  alias Predictex.Fifa
  alias Predictex.Tournament
  alias Predictex.Tournament.{Fixture, Round}

  @default_url "https://raw.githubusercontent.com/openfootball/worldcup.json/master/2026/worldcup.json"

  # Replaced on re-sync. Deliberately excludes cohort_*_pct (admin data) and inserted_at.
  @replace_on_conflict [
    :team1,
    :team2,
    :group,
    :kickoff_at,
    :status,
    :home_goals,
    :away_goals,
    :first_scorer_side,
    :first_scorer_player,
    :first_goal_owngoal,
    :goals,
    :round_id,
    :updated_at
  ]

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

    %Fixture{}
    |> Fixture.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, @replace_on_conflict}, conflict_target: :external_ref)
  end
end
