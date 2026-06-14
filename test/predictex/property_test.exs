defmodule Predictex.PropertyTest do
  @moduledoc """
  Property-based tests (StreamData) for the pure engine. These assert the algebraic
  *laws* the scoring engine must obey for all inputs, complementing the worked
  examples in the unit tests.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Predictex.{Fifa, Scoring}

  defp goals, do: integer(0..9)

  describe "Scoring.score/3 laws" do
    property "an exact-score prediction always earns the full 30 base (group, no cohort)" do
      check all h <- goals(), a <- goals() do
        r = Scoring.score(%{home_goals: h, away_goals: a, booster: false}, %{home_goals: h, away_goals: a}, :group)
        assert r.base_total == 30
        assert r.outcome_correct
      end
    end

    property "group base total is always within 0..30 when no cohort is set" do
      check all ph <- goals(), pa <- goals(), fh <- goals(), fa <- goals() do
        r =
          Scoring.score(
            %{home_goals: ph, away_goals: pa, booster: false},
            %{home_goals: fh, away_goals: fa},
            :group
          )

        assert r.base_total in 0..30
      end
    end

    property "the booster doubles the fixture total and nothing else" do
      check all ph <- goals(), pa <- goals(), fh <- goals(), fa <- goals(), booster <- boolean() do
        r =
          Scoring.score(
            %{home_goals: ph, away_goals: pa, booster: booster},
            %{home_goals: fh, away_goals: fa},
            :group
          )

        assert r.fixture_total == if(booster, do: r.base_total * 2, else: r.base_total)
      end
    end

    property "scoring is symmetric under swapping home/away in both prediction and fixture" do
      check all ph <- goals(), pa <- goals(), fh <- goals(), fa <- goals() do
        base =
          Scoring.score(%{home_goals: ph, away_goals: pa, booster: false}, %{home_goals: fh, away_goals: fa}, :group).base_total

        swapped =
          Scoring.score(%{home_goals: pa, away_goals: ph, booster: false}, %{home_goals: fa, away_goals: fh}, :group).base_total

        assert base == swapped
      end
    end

    property "an exact score fires every scoreline component" do
      check all h <- goals(), a <- goals() do
        c = Scoring.score(%{home_goals: h, away_goals: a, booster: false}, %{home_goals: h, away_goals: a}, :group).components

        assert c.correct_outcome == 10
        assert c.correct_home_goals == 5
        assert c.correct_away_goals == 5
        assert c.correct_goal_difference == 5
        assert c.correct_score_bonus == 5
      end
    end
  end

  describe "Scoring.round_total/2 laws" do
    property "total = fixtures + bonus; bonus ∈ {0,20}; bonus is 20 iff every outcome is correct" do
      result = gen all ft <- integer(0..120), oc <- boolean(), do: %{fixture_total: ft, outcome_correct: oc}

      check all results <- list_of(result, max_length: 12) do
        rt = Scoring.round_total(results, true)

        assert rt.fixtures_total == Enum.sum(Enum.map(results, & &1.fixture_total))
        assert rt.total == rt.fixtures_total + rt.round_bonus
        assert rt.round_bonus in [0, 20]

        all_correct? = results != [] and Enum.all?(results, & &1.outcome_correct)
        assert rt.round_bonus == if(all_correct?, do: 20, else: 0)
      end
    end
  end

  describe "Fifa.assign_rounds/1 laws" do
    property "every group fixture maps to a group-round ordinal in 1..3" do
      day = gen all d <- integer(1..28), do: "2026-06-" <> String.pad_leading(Integer.to_string(d), 2, "0")

      group_fixture =
        gen all date <- day do
          %{stage: :group, group: "G", date: date, time: "12:00", team1: "X", team2: "Y"}
        end

      check all fixtures <- list_of(group_fixture, min_length: 1, max_length: 12) do
        for f <- Fifa.assign_rounds(fixtures) do
          assert f.game_round.ordinal in 1..3
          assert f.game_round.stage == :group
        end
      end
    end
  end
end
