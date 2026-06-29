defmodule Predictex.Scoring.Leaderboard do
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

  alias Predictex.{Fifa, Scoring.Ranking, Results.Openfootball, Scoring.Engine}

  @doc """
  Build ranked standings. Returns a list of player result maps sorted by `:total`
  descending (ties broken by name), each with `:name`, `:fixtures_total`,
  `:round_bonus_total`, `:total`, `:bonus_by_round`, and a per-fixture `:breakdown`.

  This is the team-name-join adapter over the shared `Predictex.Scoring.Ranking` core: it
  matches each prediction to its fixture by normalized team names and hands the
  core already-scored entries; the core owns the fold (totals, Round Bonus, sort).
  """
  @spec build([map()], [map()], [map()]) :: [map()]
  def build(fixtures, players, cohort \\ []) do
    cohort_idx = Map.new(cohort, &{match_key(&1.home_team, &1.away_team), &1})

    fixtures =
      fixtures
      |> Fifa.assign_rounds()
      |> Enum.map(&attach_cohort(&1, cohort_idx))

    fixture_idx = Map.new(fixtures, &{match_key(&1.team1, &1.team2), &1})

    scored_players = Enum.map(players, &scored_player(&1, fixture_idx))
    Ranking.rank(scored_players, round_fixtures(fixtures))
  end

  @doc "Derive fixtures from a decoded openfootball document, for callers that have the raw JSON."
  @spec fixtures_from_openfootball(map()) :: [map()]
  def fixtures_from_openfootball(doc), do: Openfootball.parse(doc)

  # --- internals ---

  # The team-name join: match each prediction to its completed fixture by
  # normalized names and score it, tagging every entry with its round ordinal and
  # the full `fixture` (which the CLI breakdown prints). The `Ranking` core folds
  # these into totals.
  defp scored_player(player, fixture_idx) do
    scored =
      player
      |> Map.get(:predictions, [])
      |> Enum.flat_map(fn input ->
        case Map.get(fixture_idx, match_key(input.home_team, input.away_team)) do
          %{status: :completed} = fx ->
            [
              %{
                fixture: fx,
                ordinal: fx.game_round.ordinal,
                result: Engine.score(to_pred(input), fx, fx.stage)
              }
            ]

          _ ->
            []
        end
      end)

    %{name: Map.get(player, :name), scored: scored}
  end

  # The fixture universe the core needs to size and complete each round.
  defp round_fixtures(fixtures) do
    Enum.map(fixtures, &%{ordinal: &1.game_round.ordinal, completed?: &1.status == :completed})
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
