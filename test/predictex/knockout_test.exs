defmodule Predictex.KnockoutTest do
  use ExUnit.Case, async: true

  alias Predictex.Knockout

  test "resolved_team?/1 is false for every placeholder form" do
    refute Knockout.resolved_team?("1C")
    refute Knockout.resolved_team?("2F")
    refute Knockout.resolved_team?("3A/B/C/D/F")
    refute Knockout.resolved_team?("W89")
    refute Knockout.resolved_team?("L101")
  end

  test "resolved_team?/1 is true for real team names" do
    assert Knockout.resolved_team?("Croatia")
    assert Knockout.resolved_team?("South Africa")
    assert Knockout.resolved_team?("Côte d'Ivoire")
  end

  test "resolved_team?/1 is total — non-binaries and empties never raise" do
    refute Knockout.resolved_team?(nil)
    # empty string is not a placeholder pattern, so it counts as (degenerate) resolved
    assert Knockout.resolved_team?("")
  end

  describe "slot_label/1 (predictex-94u)" do
    test "a real team name passes through unchanged" do
      assert Knockout.slot_label("Brazil") == "Brazil"
      assert Knockout.slot_label("Côte d'Ivoire") == "Côte d'Ivoire"
    end

    test "spells out each placeholder form" do
      assert Knockout.slot_label("1A") == "Winner A"
      assert Knockout.slot_label("2B") == "Runners-up B"
      assert Knockout.slot_label("3A/B/C/D/F") == "3rd · A/B/C/D/F"
      assert Knockout.slot_label("W89") == "Winner of 89"
      assert Knockout.slot_label("L101") == "Loser of 101"
    end

    test "is total — a non-binary returns an empty string" do
      assert Knockout.slot_label(nil) == ""
    end
  end

  describe "parse_slot/1 (predictex-dum)" do
    test "classifies each placeholder form" do
      assert Knockout.parse_slot("1A") == {:winner, "A"}
      assert Knockout.parse_slot("2B") == {:runner_up, "B"}
      assert Knockout.parse_slot("3A/B/C/D/F") == {:third, ["A", "B", "C", "D", "F"]}
      assert Knockout.parse_slot("W89") == {:later, "W89"}
      assert Knockout.parse_slot("L101") == {:later, "L101"}
    end

    test "a real team name is {:resolved, name}" do
      assert Knockout.parse_slot("Brazil") == {:resolved, "Brazil"}
      assert Knockout.parse_slot("Côte d'Ivoire") == {:resolved, "Côte d'Ivoire"}
    end

    test "is total and agrees with resolved_team?/1" do
      for s <- ["1A", "2B", "3A/B/C/D/F", "W89", "Brazil", ""] do
        assert match?({:resolved, _}, Knockout.parse_slot(s)) == Knockout.resolved_team?(s)
      end

      assert Knockout.parse_slot(nil) == {:resolved, ""}
    end
  end
end
