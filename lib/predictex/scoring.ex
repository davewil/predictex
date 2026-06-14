defmodule Predictex.Scoring do
  @moduledoc """
  Pure scoring engine for the FIFA World Cup predictor.

  Every function here is a **pure function**: it reads plain data (predictions and
  fixtures, as maps or structs) and returns plain data. No `Repo`, no clock reads,
  no I/O — same inputs always produce the same output.

  All openfootball parsing and field derivation (deriving `first_scorer_side`,
  `first_goal_owngoal`, etc. from goal arrays) happens upstream in the ingestion
  layer. This module trusts the shape it is given. See `docs/rules.md` (§7 and the
  §9 "implementation contract") for the rules these functions encode.

  Precondition: a fixture passed to `score/3` is **completed**, with integer
  `home_goals`/`away_goals` (the full-time / regulation result — extra time and
  penalties are excluded upstream).
  """

  # Point values — one editable place for the scoring table (docs/rules.md §7).
  @points %{
    outcome: 10,
    home_goals: 5,
    away_goals: 5,
    goal_difference: 5,
    score_bonus: 5,
    risky: 10,
    first_team: 5,
    first_player: 10,
    round_bonus: 20
  }

  # Risky bonus fires when the predicted winning side's cohort share is below this %.
  @risky_threshold 20

  # Booster multiplies a fixture's total only — never the round bonus (settled ruling).
  @booster_multiplier 2

  @type stage :: :group | :knockout

  @doc """
  Score a single prediction against a fixture result.

  `stage` is `:group` or `:knockout`; the first-team and first-player components
  only apply in the knockout stage.

  Returns a map with:

    * `:components` — each scoring line and the points it earned
    * `:outcome_correct` — whether the result (home/draw/away) was predicted (drives the round bonus)
    * `:base_total` — sum of all components, before the booster
    * `:booster` — whether the 2x booster was active on this fixture
    * `:fixture_total` — `base_total`, doubled when the booster is active
  """
  @spec score(map(), map(), stage()) :: map()
  def score(prediction, fixture, stage) when stage in [:group, :knockout] do
    ph = f(prediction, :home_goals)
    pa = f(prediction, :away_goals)
    ah = f(fixture, :home_goals)
    aa = f(fixture, :away_goals)

    pred_outcome = outcome(ph, pa)
    actual_outcome = outcome(ah, aa)
    outcome_correct? = pred_outcome == actual_outcome

    components = %{
      correct_outcome: award(outcome_correct?, @points.outcome),
      correct_home_goals: award(ph == ah, @points.home_goals),
      correct_away_goals: award(pa == aa, @points.away_goals),
      correct_goal_difference: award(ph - pa == ah - aa, @points.goal_difference),
      correct_score_bonus: award(ph == ah and pa == aa, @points.score_bonus),
      risky_bonus: risky_bonus(pred_outcome, outcome_correct?, fixture),
      first_team_to_score: first_team_points(prediction, fixture, stage),
      first_player_to_score: first_player_points(prediction, fixture, stage)
    }

    base_total = components |> Map.values() |> Enum.sum()
    booster? = f(prediction, :booster) == true
    fixture_total = if booster?, do: base_total * @booster_multiplier, else: base_total

    %{
      components: components,
      outcome_correct: outcome_correct?,
      base_total: base_total,
      booster: booster?,
      fixture_total: fixture_total
    }
  end

  @doc """
  Aggregate the per-fixture results of a round into a round total.

  Takes the list of maps returned by `score/3` for every fixture in the round and
  adds the Round Bonus (+20, undoubled) when the round is complete and **every**
  fixture outcome was predicted correctly.
  """
  @spec round_total([map()], boolean()) :: map()
  def round_total(fixture_results, round_complete? \\ true) when is_list(fixture_results) do
    fixtures_total = fixture_results |> Enum.map(& &1.fixture_total) |> Enum.sum()

    all_outcomes_correct? =
      round_complete? and fixture_results != [] and
        Enum.all?(fixture_results, & &1.outcome_correct)

    round_bonus = award(all_outcomes_correct?, @points.round_bonus)

    %{
      fixtures_total: fixtures_total,
      round_bonus: round_bonus,
      total: fixtures_total + round_bonus
    }
  end

  # --- internals ---

  defp outcome(h, a) when h > a, do: :home_win
  defp outcome(h, a) when h < a, do: :away_win
  defp outcome(_, _), do: :draw

  defp award(true, points), do: points
  defp award(false, _points), do: 0

  # Risky: a correct Home/Away win (never a draw) where the predicted winner's
  # cohort share is below threshold. Skipped when the cohort % is unknown (nil).
  defp risky_bonus(pred_outcome, outcome_correct?, fixture)
       when pred_outcome in [:home_win, :away_win] do
    cohort =
      case pred_outcome do
        :home_win -> f(fixture, :cohort_home_pct)
        :away_win -> f(fixture, :cohort_away_pct)
      end

    if outcome_correct? and is_number(cohort) and cohort < @risky_threshold do
      @points.risky
    else
      0
    end
  end

  defp risky_bonus(_draw, _correct, _fixture), do: 0

  # First team to score — knockout only. An own goal still counts for a team;
  # the ingestion layer already credits `first_scorer_side` to the beneficiary.
  defp first_team_points(prediction, fixture, :knockout) do
    actual_side = f(fixture, :first_scorer_side)
    pred_side = f(prediction, :first_scorer_side)
    award(not is_nil(actual_side) and pred_side == actual_side, @points.first_team)
  end

  defp first_team_points(_p, _f, :group), do: 0

  # First player to score — knockout only. Voided when the first goal was an own goal.
  defp first_player_points(prediction, fixture, :knockout) do
    own_goal? = f(fixture, :first_goal_owngoal) == true
    actual_player = norm(f(fixture, :first_scorer_player))
    pred_player = norm(f(prediction, :first_scorer_player))

    matched? = not is_nil(actual_player) and pred_player == actual_player
    award(matched? and not own_goal?, @points.first_player)
  end

  defp first_player_points(_p, _f, :group), do: 0

  # Uniform field access for both Ecto structs and plain maps (keeps the engine
  # decoupled from any schema, so tests need no database).
  defp f(data, key), do: Map.get(data, key)

  defp norm(nil), do: nil
  defp norm(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
end
