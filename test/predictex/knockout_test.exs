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
end
