defmodule PredictexWeb.FlagsTest do
  use ExUnit.Case, async: true

  alias PredictexWeb.Flags

  test "known nations map to a non-default flag" do
    refute Flags.flag("Mexico") == "⚽"
    refute Flags.flag("Argentina") == "⚽"
  end

  test "unknown / placeholder strings fall back to the ball" do
    # "W73" (knockout-winner slot) and "1A" (group-position slot) are real coded
    # placeholders the openfootball 2026 feed emits before fixtures resolve.
    assert Flags.flag("W73") == "⚽"
    assert Flags.flag("1A") == "⚽"
    assert Flags.flag(nil) == "⚽"
    assert Flags.flag("") == "⚽"
  end

  test "known/0 returns the full mapped nation list" do
    known = Flags.known()
    assert is_list(known)
    assert length(known) == 48
    assert "Mexico" in known
  end
end
