defmodule Predictex.Results.OpenfootballTest do
  use ExUnit.Case, async: true

  alias Predictex.Results.Openfootball

  describe "stage_for/1" do
    test "Matchday N is the group stage" do
      assert Openfootball.stage_for("Matchday 1") == :group
      assert Openfootball.stage_for("Matchday 17") == :group
    end

    test "every knockout round name classifies as :knockout" do
      for r <- ["Round of 32", "Round of 16", "Quarter-final", "Semi-final", "Match for third place", "Final"] do
        assert Openfootball.stage_for(r) == :knockout, "expected #{inspect(r)} to be knockout"
      end
    end
  end

  describe "parse_match/1" do
    test "group match: string minutes, FT score, first scorer derived (home)" do
      m = %{
        "round" => "Matchday 1",
        "date" => "2026-06-11",
        "team1" => "Mexico",
        "team2" => "South Africa",
        "score" => %{"ft" => [2, 0], "ht" => [1, 0]},
        "goals1" => [
          %{"name" => "Julián Quiñones", "minute" => "9"},
          %{"name" => "Raúl Jiménez", "minute" => "67"}
        ],
        "goals2" => [],
        "group" => "Group A"
      }

      f = Openfootball.parse_match(m)
      assert f.stage == :group
      assert f.status == :completed
      assert {f.home_goals, f.away_goals} == {2, 0}
      assert f.first_scorer_side == :home
      assert f.first_scorer_player == "Julián Quiñones"
      refute f.first_goal_owngoal
      assert f.external_ref == "2026-06-11 Mexico v South Africa"
    end

    test "no FT score => scheduled with nil goals" do
      f = Openfootball.parse_match(%{"round" => "Matchday 1", "team1" => "A", "team2" => "B", "score" => %{}})
      assert f.status == :scheduled
      assert {f.home_goals, f.away_goals} == {nil, nil}
    end

    test "earliest goal across both sides wins (away scores first)" do
      m = %{
        "round" => "Matchday 2",
        "team1" => "A",
        "team2" => "B",
        "score" => %{"ft" => [1, 1]},
        "goals1" => [%{"name" => "Home Late", "minute" => 80}],
        "goals2" => [%{"name" => "Away Early", "minute" => 10}]
      }

      f = Openfootball.parse_match(m)
      assert f.first_scorer_side == :away
      assert f.first_scorer_player == "Away Early"
    end

    test "stoppage-time ordering: 45+2 comes before minute 46" do
      m = %{
        "round" => "Matchday 2",
        "team1" => "A",
        "team2" => "B",
        "score" => %{"ft" => [1, 1]},
        "goals1" => [%{"name" => "Stoppage", "minute" => "45+2"}],
        "goals2" => [%{"name" => "Minute46", "minute" => 46}]
      }

      assert Openfootball.parse_match(m).first_scorer_player == "Stoppage"
    end

    test "own goal: first scorer is the genuine earliest goal, side from beneficiary array" do
      # Real 2022: Canada 1–2 Morocco. Aguerd (Morocco) OG at 40' sits in Canada's array,
      # but the actual first goal was Ziyech (away) at 4'.
      m = %{
        "round" => "Matchday 12",
        "team1" => "Canada",
        "team2" => "Morocco",
        "score" => %{"ft" => [1, 2]},
        "goals1" => [%{"name" => "Nayef Aguerd", "minute" => 40, "owngoal" => true}],
        "goals2" => [
          %{"name" => "Hakim Ziyech", "minute" => 4},
          %{"name" => "Youssef En-Nesyri", "minute" => 23}
        ]
      }

      f = Openfootball.parse_match(m)
      assert f.first_scorer_side == :away
      assert f.first_scorer_player == "Hakim Ziyech"
    end

    test "an own goal that IS the first goal counts for the beneficiary side, flagged owngoal" do
      m = %{
        "round" => "Round of 16",
        "team1" => "Home",
        "team2" => "Away",
        "score" => %{"ft" => [0, 1]},
        "goals1" => [],
        "goals2" => [%{"name" => "Own Goaler", "minute" => 20, "owngoal" => true}]
      }

      f = Openfootball.parse_match(m)
      assert f.first_scorer_side == :away
      assert f.first_scorer_player == "Own Goaler"
      assert f.first_goal_owngoal
    end
  end

  describe "parse/1" do
    test "parses a document's matches list" do
      doc = %{"matches" => [%{"round" => "Final", "team1" => "A", "team2" => "B", "score" => %{"ft" => [0, 0]}}]}
      assert [%{stage: :knockout, status: :completed}] = Openfootball.parse(doc)
    end

    test "a non-document yields an empty list" do
      assert Openfootball.parse(%{}) == []
    end
  end
end
