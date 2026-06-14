defmodule Predictex.ScoringTest do
  use ExUnit.Case, async: true

  alias Predictex.Scoring

  # --- builders: plain maps mirroring the fields the pure engine reads ---

  defp pred(attrs) do
    Map.merge(
      %{
        home_goals: 0,
        away_goals: 0,
        first_scorer_side: nil,
        first_scorer_player: nil,
        booster: false
      },
      Map.new(attrs)
    )
  end

  defp fixture(attrs) do
    Map.merge(
      %{
        home_goals: 0,
        away_goals: 0,
        first_scorer_side: nil,
        first_scorer_player: nil,
        first_goal_owngoal: false,
        cohort_home_pct: nil,
        cohort_draw_pct: nil,
        cohort_away_pct: nil
      },
      Map.new(attrs)
    )
  end

  defp result(fixture_total, outcome_correct),
    do: %{fixture_total: fixture_total, outcome_correct: outcome_correct}

  describe "score/3 — scoreline components are additive" do
    test "exact correct score stacks outcome + home + away + GD + score bonus = 30" do
      r = Scoring.score(pred(%{home_goals: 2, away_goals: 1}), fixture(%{home_goals: 2, away_goals: 1}), :group)

      assert r.components == %{
               correct_outcome: 10,
               correct_home_goals: 5,
               correct_away_goals: 5,
               correct_goal_difference: 5,
               correct_score_bonus: 5,
               risky_bonus: 0,
               first_team_to_score: 0,
               first_player_to_score: 0
             }

      assert r.base_total == 30
      assert r.fixture_total == 30
      assert r.outcome_correct
    end

    test "correct outcome + goal difference but wrong exact score = 15" do
      r = Scoring.score(pred(%{home_goals: 2, away_goals: 1}), fixture(%{home_goals: 3, away_goals: 2}), :group)

      assert r.components.correct_outcome == 10
      assert r.components.correct_goal_difference == 5
      assert r.components.correct_home_goals == 0
      assert r.components.correct_away_goals == 0
      assert r.components.correct_score_bonus == 0
      assert r.base_total == 15
    end

    test "correct outcome only = 10" do
      r = Scoring.score(pred(%{home_goals: 1, away_goals: 0}), fixture(%{home_goals: 3, away_goals: 1}), :group)
      assert r.base_total == 10
    end

    test "wrong outcome with nothing else matching = 0" do
      r = Scoring.score(pred(%{home_goals: 2, away_goals: 1}), fixture(%{home_goals: 0, away_goals: 2}), :group)
      assert r.base_total == 0
      refute r.outcome_correct
    end

    test "correct home goals only (wrong outcome) = 5" do
      r = Scoring.score(pred(%{home_goals: 2, away_goals: 3}), fixture(%{home_goals: 2, away_goals: 0}), :group)
      assert r.components.correct_home_goals == 5
      assert r.components.correct_outcome == 0
      assert r.base_total == 5
    end

    test "exact draw stacks to 30" do
      r = Scoring.score(pred(%{home_goals: 1, away_goals: 1}), fixture(%{home_goals: 1, away_goals: 1}), :group)
      assert r.base_total == 30
    end
  end

  describe "score/3 — booster" do
    test "booster doubles the fixture total only" do
      r =
        Scoring.score(
          pred(%{home_goals: 2, away_goals: 1, booster: true}),
          fixture(%{home_goals: 2, away_goals: 1}),
          :group
        )

      assert r.base_total == 30
      assert r.booster
      assert r.fixture_total == 60
    end
  end

  describe "score/3 — risky bonus" do
    test "fires on a correct home win when cohort_home_pct < 20" do
      r =
        Scoring.score(
          pred(%{home_goals: 1, away_goals: 0}),
          fixture(%{home_goals: 1, away_goals: 0, cohort_home_pct: 15}),
          :group
        )

      assert r.components.risky_bonus == 10
      assert r.base_total == 40
    end

    test "fires on a correct away win when cohort_away_pct < 20" do
      r =
        Scoring.score(
          pred(%{home_goals: 0, away_goals: 2}),
          fixture(%{home_goals: 0, away_goals: 2, cohort_away_pct: 10}),
          :group
        )

      assert r.components.risky_bonus == 10
    end

    test "does not fire when cohort share >= 20" do
      r =
        Scoring.score(
          pred(%{home_goals: 1, away_goals: 0}),
          fixture(%{home_goals: 1, away_goals: 0, cohort_home_pct: 25}),
          :group
        )

      assert r.components.risky_bonus == 0
    end

    test "skipped when cohort % is nil" do
      r = Scoring.score(pred(%{home_goals: 1, away_goals: 0}), fixture(%{home_goals: 1, away_goals: 0}), :group)
      assert r.components.risky_bonus == 0
    end

    test "never fires for a correct draw, even with low cohort" do
      r =
        Scoring.score(
          pred(%{home_goals: 1, away_goals: 1}),
          fixture(%{home_goals: 1, away_goals: 1, cohort_draw_pct: 5}),
          :group
        )

      assert r.components.risky_bonus == 0
    end

    test "independent of exact score — a correct outcome is enough" do
      r =
        Scoring.score(
          pred(%{home_goals: 2, away_goals: 0}),
          fixture(%{home_goals: 3, away_goals: 0, cohort_home_pct: 10}),
          :group
        )

      assert r.components.risky_bonus == 10
      assert r.components.correct_score_bonus == 0
    end
  end

  describe "score/3 — knockout first team / first player to score" do
    test "first team to score correct = +5" do
      r =
        Scoring.score(
          pred(%{home_goals: 1, away_goals: 0, first_scorer_side: :home}),
          fixture(%{home_goals: 1, away_goals: 0, first_scorer_side: :home}),
          :knockout
        )

      assert r.components.first_team_to_score == 5
    end

    test "first player to score correct (no own goal) = +10" do
      r =
        Scoring.score(
          pred(%{home_goals: 1, away_goals: 0, first_scorer_side: :home, first_scorer_player: "Messi"}),
          fixture(%{home_goals: 1, away_goals: 0, first_scorer_side: :home, first_scorer_player: "Messi"}),
          :knockout
        )

      assert r.components.first_player_to_score == 10
    end

    test "own goal voids the first PLAYER but the first TEAM still scores" do
      r =
        Scoring.score(
          pred(%{home_goals: 0, away_goals: 1, first_scorer_side: :away, first_scorer_player: "Enzo Fernández"}),
          fixture(%{
            home_goals: 0,
            away_goals: 1,
            first_scorer_side: :away,
            first_scorer_player: "Enzo Fernández",
            first_goal_owngoal: true
          }),
          :knockout
        )

      assert r.components.first_team_to_score == 5
      assert r.components.first_player_to_score == 0
    end

    test "player name match is whitespace/case insensitive" do
      r =
        Scoring.score(
          pred(%{home_goals: 1, away_goals: 0, first_scorer_side: :home, first_scorer_player: "  messi "}),
          fixture(%{home_goals: 1, away_goals: 0, first_scorer_side: :home, first_scorer_player: "Messi"}),
          :knockout
        )

      assert r.components.first_player_to_score == 10
    end

    test "group stage ignores first team / player even when predicted" do
      r =
        Scoring.score(
          pred(%{home_goals: 1, away_goals: 0, first_scorer_side: :home, first_scorer_player: "Messi"}),
          fixture(%{home_goals: 1, away_goals: 0, first_scorer_side: :home, first_scorer_player: "Messi"}),
          :group
        )

      assert r.components.first_team_to_score == 0
      assert r.components.first_player_to_score == 0
    end

    test "0-0 knockout: no first scorer means no team points" do
      r =
        Scoring.score(
          pred(%{home_goals: 0, away_goals: 0, first_scorer_side: :home}),
          fixture(%{home_goals: 0, away_goals: 0, first_scorer_side: nil}),
          :knockout
        )

      assert r.components.first_team_to_score == 0
    end
  end

  describe "round_total/2" do
    test "adds +20 when every outcome is correct in a complete round" do
      results = [result(30, true), result(10, true), result(15, true)]
      assert Scoring.round_total(results) == %{fixtures_total: 55, round_bonus: 20, total: 75}
    end

    test "no round bonus when any outcome is wrong" do
      results = [result(30, true), result(0, false)]
      assert Scoring.round_total(results).round_bonus == 0
    end

    test "round bonus is NOT doubled by a boosted fixture" do
      results = [result(60, true), result(10, true), result(15, true)]
      rt = Scoring.round_total(results)
      assert rt.fixtures_total == 85
      assert rt.round_bonus == 20
      assert rt.total == 105
    end

    test "no round bonus for an incomplete round, even if all-so-far correct" do
      results = [result(30, true), result(10, true)]
      assert Scoring.round_total(results, false).round_bonus == 0
    end

    test "an empty round yields no bonus" do
      assert Scoring.round_total([]).round_bonus == 0
    end
  end
end
