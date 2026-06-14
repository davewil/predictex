defmodule Predictex.Leaderboard do
  @moduledoc """
  Pure leaderboard aggregation: score every player's predictions against the
  fixtures and rank them. No DB — this drives the `mix predictex.leaderboard` task
  and is fully testable in isolation.

  Shapes (all atom-keyed; the mix task normalizes JSON into these):

    * `fixtures` — as produced by `Predictex.Results.Openfootball.parse/1`
    * `players` — `[%{name: String, predictions: [prediction_input]}]`
    * `prediction_input` — `%{home_team:, away_team:, home:, away:, booster:,
      first_scorer_side:, first_scorer_player:}`
    * `cohort` — `[%{home_team:, away_team:, home:, draw:, away:}]` (FIFA global %)

  Only **completed** fixtures a player actually predicted are scored — which is how
  the "score from join onward" ruling falls out for free (no prediction → not scored).

  The **Round Bonus** (+20) is computed in the game's terms: fixtures are mapped to
  the 8 FIFA game rounds by `Predictex.Fifa`, and the bonus is awarded for a round
  only when it is fully completed and the player predicted every one of its outcomes
  correctly.
  """

  alias Predictex.{Fifa, Results.Openfootball, Scoring}

  @doc """
  Build ranked standings. Returns a list of player result maps sorted by `:total`
  descending (ties broken by name), each with `:name`, `:fixtures_total`,
  `:round_bonus_total`, `:total`, and a per-fixture `:breakdown`.
  """
  @spec build([map()], [map()], [map()]) :: [map()]
  def build(fixtures, players, cohort \\ []) do
    cohort_idx = Map.new(cohort, &{match_key(&1.home_team, &1.away_team), &1})

    fixtures =
      fixtures
      |> Fifa.assign_rounds()
      |> Enum.map(&attach_cohort(&1, cohort_idx))

    fixture_idx = Map.new(fixtures, &{match_key(&1.team1, &1.team2), &1})

    rounds =
      fixtures
      |> Enum.group_by(& &1.game_round.ordinal)
      |> Map.new(fn {ordinal, fxs} ->
        {ordinal,
         %{
           keys: Enum.map(fxs, &match_key(&1.team1, &1.team2)),
           complete?: Enum.all?(fxs, &(&1.status == :completed))
         }}
      end)

    players
    |> Enum.map(&score_player(&1, fixture_idx, rounds))
    |> Enum.sort_by(&{-&1.total, &1.name})
  end

  @doc "Derive fixtures from a decoded openfootball document, for callers that have the raw JSON."
  @spec fixtures_from_openfootball(map()) :: [map()]
  def fixtures_from_openfootball(doc), do: Openfootball.parse(doc)

  # --- internals ---

  defp score_player(player, fixture_idx, rounds) do
    scored =
      player
      |> Map.get(:predictions, [])
      |> Enum.flat_map(fn input ->
        case Map.get(fixture_idx, match_key(input.home_team, input.away_team)) do
          %{status: :completed} = fx ->
            [%{fixture: fx, ordinal: fx.game_round.ordinal, result: Scoring.score(to_pred(input), fx, fx.stage)}]

          _ ->
            []
        end
      end)

    fixtures_total = scored |> Enum.map(& &1.result.fixture_total) |> Enum.sum()
    round_bonus_total = round_bonus_total(scored, rounds)

    %{
      name: Map.get(player, :name),
      fixtures_total: fixtures_total,
      round_bonus_total: round_bonus_total,
      total: fixtures_total + round_bonus_total,
      breakdown: scored
    }
  end

  # Sum the Round Bonus across every round the player fully and correctly predicted.
  defp round_bonus_total(scored, rounds) do
    scored
    |> Enum.group_by(& &1.ordinal)
    |> Enum.map(fn {ordinal, entries} ->
      meta = Map.get(rounds, ordinal)
      results = Enum.map(entries, & &1.result)

      complete? =
        not is_nil(ordinal) and meta != nil and meta.complete? and
          length(entries) == length(meta.keys)

      Scoring.round_total(results, complete?).round_bonus
    end)
    |> Enum.sum()
  end

  defp attach_cohort(fixture, cohort_idx) do
    case Map.get(cohort_idx, match_key(fixture.team1, fixture.team2)) do
      nil ->
        fixture

      c ->
        Map.merge(fixture, %{
          cohort_home_pct: Map.get(c, :home),
          cohort_draw_pct: Map.get(c, :draw),
          cohort_away_pct: Map.get(c, :away)
        })
    end
  end

  defp to_pred(input) do
    %{
      home_goals: input.home,
      away_goals: input.away,
      booster: Map.get(input, :booster, false) == true,
      first_scorer_side: side(Map.get(input, :first_scorer_side)),
      first_scorer_player: Map.get(input, :first_scorer_player)
    }
  end

  defp side(s) when s in [:home, "home"], do: :home
  defp side(s) when s in [:away, "away"], do: :away
  defp side(_), do: nil

  # Match predictions to fixtures by home/away team names, normalized.
  defp match_key(team1, team2), do: {norm(team1), norm(team2)}

  defp norm(nil), do: nil
  defp norm(s) when is_binary(s), do: s |> String.trim() |> String.downcase()
end
