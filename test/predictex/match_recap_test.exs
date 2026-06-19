defmodule Predictex.MatchRecapTest do
  use ExUnit.Case, async: true
  alias Predictex.MatchRecap

  defp fixture(attrs \\ %{}) do
    Map.merge(
      %{home_goals: 2, away_goals: 1, status: :completed, round: %{stage: :group}},
      attrs
    )
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
