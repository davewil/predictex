defmodule Predictex.BracketTest do
  use ExUnit.Case, async: true

  alias Predictex.Bracket
  alias Predictex.GroupTables.Row

  defp tables do
    %{
      "C" => [
        %Row{team: "Croatia", group: "C", rank: 1},
        %Row{team: "Belgium", group: "C", rank: 2},
        %Row{team: "Morocco", group: "C", rank: 3}
      ]
    }
  end

  test "resolves a group-winner placeholder to the rank-1 team" do
    assert Bracket.resolve_slot("1C", tables()) == {:exact, "Croatia"}
  end

  test "resolves a runner-up placeholder to the rank-2 team" do
    assert Bracket.resolve_slot("2C", tables()) == {:exact, "Belgium"}
  end

  test "returns a candidate set for a third-placed placeholder" do
    assert Bracket.resolve_slot("3A/B/C/D/F", tables()) == {:candidate_set, ~w(A B C D F)}
  end

  test "passes an already-resolved real team name through as :resolved" do
    assert Bracket.resolve_slot("Germany", tables()) == {:resolved, "Germany"}
  end

  test "labels a winner/runner-up slot whose group has no ranked team yet as :tbd" do
    assert Bracket.resolve_slot("1Z", tables()) == {:tbd, "Winner Z"}
    assert Bracket.resolve_slot("2Z", tables()) == {:tbd, "Runners-up Z"}
  end

  test "is total — a later-round W/L marker and garbage never raise" do
    assert Bracket.resolve_slot("W74", tables()) == {:tbd, "W74"}
    assert Bracket.resolve_slot("", tables()) == {:resolved, ""}
  end
end
