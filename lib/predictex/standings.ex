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

  alias Predictex.Repo
  alias Predictex.Scoring
  alias Predictex.Accounts.Player
  alias Predictex.Tournament.Fixture

  @doc "Ranked standings for the whole league, sorted by total (desc), ties by name."
  def leaderboard do
    fixtures = Repo.all(from f in Fixture, preload: :round)
    players = Repo.all(from p in Player, preload: :predictions)
    rank(players, fixtures)
  end

  @doc """
  Pure ranking over already-loaded players and fixtures.

  `fixtures` must have `:round` loaded; `players` must have `:predictions` loaded.
  Returns a list of `%{player_id, name, fixtures_total, round_bonus_total, total,
  bonus_by_round, breakdown}` sorted by `:total` descending, ties broken by name.
  `bonus_by_round` maps each round ordinal to its Round Bonus; each `breakdown`
  entry carries `%{ordinal, fixture_id, result}`.
  """
  def rank(players, fixtures) do
    fixtures_by_id = Map.new(fixtures, &{&1.id, &1})
    rounds_meta = round_meta(fixtures)

    players
    |> Enum.map(&score_player(&1, fixtures_by_id, rounds_meta))
    |> Enum.sort_by(&{-&1.total, &1.name})
  end

  # --- internals ---

  defp score_player(player, fixtures_by_id, rounds_meta) do
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

    fixtures_total = scored |> Enum.map(& &1.result.fixture_total) |> Enum.sum()
    bonus_by_round = bonus_by_round(scored, rounds_meta)
    round_bonus_total = bonus_by_round |> Map.values() |> Enum.sum()

    %{
      player_id: player.id,
      name: player.display_name,
      fixtures_total: fixtures_total,
      round_bonus_total: round_bonus_total,
      total: fixtures_total + round_bonus_total,
      bonus_by_round: bonus_by_round,
      breakdown: scored
    }
  end

  # Round Bonus per round ordinal (one computation feeds both the per-round figure and
  # the total, so they cannot drift).
  defp bonus_by_round(scored, rounds_meta) do
    scored
    |> Enum.group_by(& &1.ordinal)
    |> Map.new(fn {ordinal, entries} ->
      meta = Map.get(rounds_meta, ordinal)
      results = Enum.map(entries, & &1.result)

      complete? =
        not is_nil(ordinal) and meta != nil and meta.complete? and
          length(entries) == meta.count

      {ordinal, Scoring.round_total(results, complete?).round_bonus}
    end)
  end

  # Per-round-ordinal fixture count and whether every fixture is completed.
  defp round_meta(fixtures) do
    fixtures
    |> Enum.group_by(& &1.round.ordinal)
    |> Map.new(fn {ordinal, fxs} ->
      {ordinal, %{count: length(fxs), complete?: Enum.all?(fxs, &(&1.status == :completed))}}
    end)
  end
end
