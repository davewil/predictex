defmodule Predictex.GroupTablesTest do
  use ExUnit.Case, async: true

  alias Predictex.GroupTables
  alias Predictex.GroupTables.Row

  defp fx(group, t1, t2, hg, ag, status \\ :completed) do
    %{group: group, team1: t1, team2: t2, home_goals: hg, away_goals: ag, status: status}
  end

  test "ranks a group by points, then goal difference, then goals for" do
    # Group A: Mexico beats Poland 2-0; Argentina beats Poland 1-0; Mexico draws Argentina 1-1.
    fixtures = [
      fx("A", "Mexico", "Poland", 2, 0),
      fx("A", "Argentina", "Poland", 1, 0),
      fx("A", "Mexico", "Argentina", 1, 1)
    ]

    [a, b, c] = GroupTables.build(fixtures)["A"]

    # Mexico: 4 pts, GD +2. Argentina: 4 pts, GD +1. Poland: 0 pts, GD -3.
    assert {a.team, a.rank, a.points, a.gd} == {"Mexico", 1, 4, 2}
    assert {b.team, b.rank, b.points, b.gd} == {"Argentina", 2, 4, 1}
    assert {c.team, c.rank, c.points, c.gd} == {"Poland", 3, 0, -3}
    assert %Row{} = a
  end

  test "counts wins, draws, losses, goals for/against and played" do
    fixtures = [fx("B", "Spain", "Japan", 3, 1), fx("B", "Spain", "Brazil", 0, 0)]
    spain = GroupTables.build(fixtures)["B"] |> Enum.find(&(&1.team == "Spain"))

    assert {spain.played, spain.won, spain.drawn, spain.lost} == {2, 1, 1, 0}
    assert {spain.gf, spain.ga, spain.points} == {3, 1, 4}
  end

  test "ignores fixtures that are not completed or have no score" do
    fixtures = [
      fx("C", "Italy", "Wales", 2, 0),
      fx("C", "Italy", "Ghana", nil, nil, :scheduled),
      fx("C", "Wales", "Ghana", 0, 0, :live)
    ]

    italy = GroupTables.build(fixtures)["C"] |> Enum.find(&(&1.team == "Italy"))
    assert italy.played == 1
    # Ghana appears (it's in the group) but has played nothing.
    ghana = GroupTables.build(fixtures)["C"] |> Enum.find(&(&1.team == "Ghana"))
    assert ghana.played == 0
  end

  test "marks adjacent teams level on points+GD+GF as a provisional tie" do
    # Two teams dead level: each beat the same patsy 1-0, drew each other 0-0.
    fixtures = [
      fx("D", "Kenya", "Chad", 1, 0),
      fx("D", "Mali", "Chad", 1, 0),
      fx("D", "Kenya", "Mali", 0, 0)
    ]

    rows = GroupTables.build(fixtures)["D"]
    [r1, r2 | _] = rows
    assert r1.provisional_tie?
    assert r2.provisional_tie?
  end
end
