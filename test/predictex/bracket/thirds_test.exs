defmodule Predictex.Bracket.ThirdsTest do
  use ExUnit.Case, async: true

  alias Predictex.Bracket.Thirds
  alias Predictex.Scoring.GroupTables.Row

  # Build a group_tables map where each group's 3rd-placed team has the given points/gd.
  defp tables_with_thirds(specs) do
    Map.new(specs, fn {group, pts, gd} ->
      third = %Row{team: "3rd-#{group}", group: group, rank: 3, points: pts, gd: gd, gf: gd}
      # rows 1 and 2 just need to exist so Enum.at(rows, 2) is the third.
      top = [
        %Row{team: "1-#{group}", group: group, rank: 1},
        %Row{team: "2-#{group}", group: group, rank: 2}
      ]

      {group, top ++ [third]}
    end)
  end

  test "ranks thirds across groups and marks the top 8 as qualifying" do
    # 12 groups A..L with descending points so the order is deterministic.
    specs = for {g, i} <- Enum.with_index(~w(A B C D E F G H I J K L)), do: {g, 30 - i, 0}
    %{entries: entries} = Thirds.ranked(tables_with_thirds(specs))

    assert length(entries) == 12
    assert Enum.at(entries, 0).position == 1
    assert Enum.at(entries, 0).qualifying?
    assert Enum.at(entries, 7).qualifying?
    refute Enum.at(entries, 8).qualifying?
  end

  test "flags a provisional cutoff tie when 8th and 9th are level" do
    # Groups A..G strong; H and I dead level on the 8/9 boundary; J,K,L weakest.
    specs =
      [{"A", 9, 5}, {"B", 9, 4}, {"C", 9, 3}, {"D", 9, 2}, {"E", 9, 1}, {"F", 8, 2}, {"G", 8, 1}] ++
        [{"H", 6, 0}, {"I", 6, 0}, {"J", 3, 0}, {"K", 2, 0}, {"L", 1, 0}]

    assert %{cutoff_provisional?: true} = Thirds.ranked(tables_with_thirds(specs))
  end

  test "no cutoff tie when 8th and 9th differ" do
    specs = for {g, i} <- Enum.with_index(~w(A B C D E F G H I J K L)), do: {g, 30 - i, 0}
    assert %{cutoff_provisional?: false} = Thirds.ranked(tables_with_thirds(specs))
  end
end
