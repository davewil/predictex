defmodule Predictex.FlagsTest do
  use Predictex.DataCase, async: false

  test "live_buzz defaults disabled and can be toggled" do
    refute FunWithFlags.enabled?(:live_buzz)
    FunWithFlags.enable(:live_buzz)
    assert FunWithFlags.enabled?(:live_buzz)
    FunWithFlags.disable(:live_buzz)
    refute FunWithFlags.enabled?(:live_buzz)
  end
end
