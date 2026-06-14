defmodule Predictex.FifaTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa

  defp gfx(group, date, time, team1, team2) do
    %{stage: :group, group: group, date: date, time: time, team1: team1, team2: team2}
  end

  defp kfx(round, team1, team2) do
    %{stage: :knockout, round: round, team1: team1, team2: team2}
  end

  describe "knockout_round/1" do
    test "maps every knockout name to the right ordinal" do
      assert %{ordinal: 4, name: "Round of 32"} = Fifa.knockout_round("Round of 32")
      assert %{ordinal: 5, name: "Round of 16"} = Fifa.knockout_round("Round of 16")
      assert %{ordinal: 6, name: "Quarter-Finals"} = Fifa.knockout_round("Quarter-final")
      assert %{ordinal: 7, name: "Semi-Finals"} = Fifa.knockout_round("Semi-final")
      assert %{ordinal: 8} = Fifa.knockout_round("Match for third place")
      assert %{ordinal: 8} = Fifa.knockout_round("Final")
    end

    test "third place and final share the Final round (ordinal 8)" do
      assert Fifa.knockout_round("Match for third place").name ==
               Fifa.knockout_round("Final").name
    end
  end

  describe "assign_rounds/1 — group stage" do
    test "chunks a 4-team group's 6 matches chronologically into Rounds 1/2/3" do
      fixtures = [
        gfx("Group A", "2026-06-19", "20:00", "A", "D"),
        gfx("Group A", "2026-06-11", "13:00", "A", "B"),
        gfx("Group A", "2026-06-15", "13:00", "A", "C"),
        gfx("Group A", "2026-06-11", "20:00", "C", "D"),
        gfx("Group A", "2026-06-19", "13:00", "B", "C"),
        gfx("Group A", "2026-06-15", "20:00", "B", "D")
      ]

      by_round =
        fixtures
        |> Fifa.assign_rounds()
        |> Enum.group_by(& &1.game_round.ordinal, &{&1.team1, &1.team2})

      assert Enum.sort(by_round[1]) == [{"A", "B"}, {"C", "D"}]
      assert Enum.sort(by_round[2]) == [{"A", "C"}, {"B", "D"}]
      assert Enum.sort(by_round[3]) == [{"A", "D"}, {"B", "C"}]
    end

    test "rounds are scoped per group (Round 1 spans every group)" do
      fixtures = [
        gfx("Group A", "2026-06-11", "13:00", "A", "B"),
        gfx("Group A", "2026-06-15", "13:00", "A", "C"),
        gfx("Group A", "2026-06-19", "13:00", "A", "D"),
        gfx("Group B", "2026-06-12", "13:00", "E", "F"),
        gfx("Group B", "2026-06-16", "13:00", "E", "G"),
        gfx("Group B", "2026-06-20", "13:00", "E", "H")
      ]

      assigned = Fifa.assign_rounds(fixtures)

      round1 = for f <- assigned, f.game_round.ordinal == 1, do: {f.team1, f.team2}
      assert Enum.sort(round1) == [{"A", "B"}, {"E", "F"}]
    end
  end

  test "assign_rounds/1 handles a mixed group + knockout slate" do
    fixtures = [
      gfx("Group A", "2026-06-11", "13:00", "A", "B"),
      kfx("Round of 16", "A", "C"),
      kfx("Final", "A", "D")
    ]

    ords = fixtures |> Fifa.assign_rounds() |> Enum.map(& &1.game_round.ordinal) |> Enum.sort()
    assert ords == [1, 5, 8]
  end
end
