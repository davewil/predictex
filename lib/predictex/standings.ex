defmodule Predictex.Standings do
  @moduledoc """
  DB-backed leaderboard: score every player's predictions against completed fixtures
  and rank them, using the same pure `Predictex.Scoring` laws as the no-DB
  `mix predictex.leaderboard` tool.

  Gather → Decide:

    * `leaderboard/0` — the I/O edge: preloads players (with predictions) and fixtures
      (with their round).
    * `rank/2` — pure: scores each completed, predicted fixture with `Scoring.score/3`
      and awards the Round Bonus per game round via `Scoring.round_total/2`.

  Because `Scoring.score/3` reads its inputs with `Map.get`, the `Prediction` and
  `Fixture` structs are passed in directly — no intermediate mapping.
  """

  import Ecto.Query, warn: false

  alias Predictex.Ranking
  alias Predictex.Repo
  alias Predictex.Scoring
  alias Predictex.Accounts.Player
  alias Predictex.Standings.Snapshot
  alias Predictex.Tournament.Fixture

  @doc """
  The single Gather edge: load every player (with predictions) and fixture (with round) once,
  as a `Standings.Snapshot`. The pure `rank/1` and `project/4` (and all `Buzz` projections) run
  over it without re-querying — so one live event loads once instead of per-projection.
  """
  def snapshot do
    {players, fixtures} = load_ranking_inputs()
    %Snapshot{players: players, fixtures: fixtures}
  end

  @doc "Ranked standings for the whole league, sorted by total (desc), ties by name."
  def leaderboard, do: rank(snapshot())

  @doc "Pure ranking over a `Standings.Snapshot`."
  def rank(%Snapshot{players: players, fixtures: fixtures}), do: rank(players, fixtures)

  @doc """
  Pure ranking over already-loaded players and fixtures.

  `fixtures` must have `:round` loaded; `players` must have `:predictions` loaded.
  Returns a list of `%{player_id, name, fixtures_total, round_bonus_total, total,
  bonus_by_round, breakdown}` sorted by `:total` descending, ties broken by name.
  `bonus_by_round` maps each round ordinal to its Round Bonus; each `breakdown`
  entry carries `%{ordinal, fixture_id, result}`.

  This is the FK-join adapter over the shared `Predictex.Ranking` core: it resolves
  each prediction to its fixture and hands the core already-scored entries; the
  core owns the fold (totals, Round Bonus, sort).
  """
  def rank(players, fixtures) do
    fixtures_by_id = Map.new(fixtures, &{&1.id, &1})
    scored_players = Enum.map(players, &scored_player(&1, fixtures_by_id))
    Ranking.rank(scored_players, round_fixtures(fixtures))
  end

  @doc """
  Re-based knockout-only standings: ranks every player over knockout-stage fixtures only,
  so the board starts from 0 at the first knockout round. Reuses the pure `rank/2`, so
  booster, risky/cohort and per-round bonus all apply within the knockout stage.
  """
  def knockout_leaderboard do
    %Snapshot{players: players, fixtures: fixtures} = snapshot()
    knockout = Enum.filter(fixtures, &(&1.round.stage == :knockout))
    rank(players, knockout)
  end

  @doc """
  Projected leaderboard over a `Standings.Snapshot`, as if `fixture_id` finished `home`-`away`.
  Swaps that one fixture to `:completed` in memory and reuses the pure `rank/2`, so booster,
  risky/cohort, and round bonus are all honoured. Pure — no `Repo`, persists nothing.
  """
  def project(%Snapshot{players: players, fixtures: fixtures}, fixture_id, home, away) do
    projected =
      Enum.map(fixtures, fn f ->
        if f.id == fixture_id,
          do: %{f | status: :completed, home_goals: home, away_goals: away},
          else: f
      end)

    rank(players, projected)
  end

  # --- internals ---

  defp load_ranking_inputs do
    fixtures = Repo.all(from f in Fixture, preload: :round)
    players = Repo.all(from p in Player, preload: :predictions)
    {players, fixtures}
  end

  # The FK join: resolve each prediction to its completed fixture and score it,
  # tagging every entry with its round ordinal and `fixture_id` (which the
  # dashboard reconciles against). The `Ranking` core folds these into totals.
  defp scored_player(player, fixtures_by_id) do
    scored =
      for prediction <- player.predictions,
          fixture = Map.get(fixtures_by_id, prediction.fixture_id),
          not is_nil(fixture) and fixture.status == :completed do
        %{
          ordinal: fixture.round.ordinal,
          fixture_id: prediction.fixture_id,
          result: Scoring.score(prediction, fixture, fixture.round.stage)
        }
      end

    %{player_id: player.id, name: player.display_name, scored: scored}
  end

  # The fixture universe the core needs to size and complete each round.
  defp round_fixtures(fixtures) do
    Enum.map(fixtures, &%{ordinal: &1.round.ordinal, completed?: &1.status == :completed})
  end
end
