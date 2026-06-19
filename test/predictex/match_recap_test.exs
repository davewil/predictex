defmodule Predictex.MatchRecapTest do
  use ExUnit.Case, async: true
  alias Predictex.MatchRecap

  defp fixture(attrs \\ %{}) do
    Map.merge(
      %{home_goals: 2, away_goals: 1, status: :completed, round: %{stage: :group}},
      attrs
    )
  end

  defp of_goal(side, type \\ :regular), do: %{side: side, type: type, player: "x", minute: "1"}

  describe "goals/2" do
    test "uses FIFA goals when their per-side count reconciles with the final score" do
      # openfootball (stale/short)
      fx = %{home_goals: 2, away_goals: 1, goals: [of_goal(:home)]}

      fifa = %{
        "HomeTeam" => %{
          "Players" => [],
          "Goals" => [%{"Type" => 2, "Minute" => "10'"}, %{"Type" => 1, "Minute" => "20'"}]
        },
        "AwayTeam" => %{"Players" => [], "Goals" => [%{"Type" => 2, "Minute" => "30'"}]}
      }

      assert MatchRecap.goal_source(fx, fifa) == :fifa
      assert length(MatchRecap.goals(fx, fifa)) == 3
    end

    test "falls back to openfootball goals when FIFA does not reconcile (capture gap)" do
      fx = %{
        home_goals: 2,
        away_goals: 1,
        goals: [
          %{side: :home, type: :regular, player: "A", minute: "1"},
          %{side: :home, type: :penalty, player: "B", minute: "2"},
          %{side: :away, type: :regular, player: "C", minute: "3"}
        ]
      }

      fifa = %{
        "HomeTeam" => %{"Players" => [], "Goals" => [%{"Type" => 2, "Minute" => "10'"}]},
        # 1-0, doesn't match 2-1
        "AwayTeam" => %{"Players" => [], "Goals" => []}
      }

      assert MatchRecap.goal_source(fx, fifa) == :openfootball
      assert length(MatchRecap.goals(fx, fifa)) == 3
    end

    test "falls back to openfootball when there is no FIFA body" do
      fx = %{home_goals: 0, away_goals: 0, goals: []}
      assert MatchRecap.goal_source(fx, nil) == :openfootball
      assert MatchRecap.goals(fx, nil) == []
    end
  end

  describe "points/2" do
    test "maps each player_id to the points their pick earned (booster folded in)" do
      preds = [
        %{player_id: 1, home_goals: 2, away_goals: 1, booster: false},
        %{player_id: 2, home_goals: 2, away_goals: 1, booster: true},
        %{player_id: 3, home_goals: 0, away_goals: 0, booster: false}
      ]

      pts = MatchRecap.points(fixture(), preds)

      assert pts[2] == pts[1] * 2, "booster doubles the same exact-score pick"
      assert pts[1] > pts[3], "an exact pick scores more than a wrong one"
      assert Map.keys(pts) |> Enum.sort() == [1, 2, 3]
    end
  end
end
