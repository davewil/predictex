defmodule PredictexWeb.PresenceTest do
  @moduledoc """
  Unit tests for the pure transforms over a `Phoenix.Presence.list/1` map —
  the shape `%{key => %{metas: [meta, ...]}}`. The cross-process tracking
  behaviour is covered by the LiveView integration tests (fixture_live, leaderboard_live).
  """
  use ExUnit.Case, async: true

  alias PredictexWeb.Presence

  describe "watcher_list/1" do
    test "maps a presence map to a sorted list of %{id, name}" do
      presence_map = %{
        "7" => %{metas: [%{name: "Sam"}]},
        "3" => %{metas: [%{name: "Ana"}]},
        "5" => %{metas: [%{name: "Dave"}]}
      }

      assert Presence.watcher_list(presence_map) == [
               %{id: "3", name: "Ana"},
               %{id: "5", name: "Dave"},
               %{id: "7", name: "Sam"}
             ]
    end

    test "collapses multiple metas for one key (multi-tab) to a single watcher" do
      presence_map = %{
        "5" => %{metas: [%{name: "Dave"}, %{name: "Dave"}]}
      }

      assert Presence.watcher_list(presence_map) == [%{id: "5", name: "Dave"}]
    end

    test "is empty for an empty presence map" do
      assert Presence.watcher_list(%{}) == []
    end
  end

  describe "watch_count/1" do
    test "counts distinct keys, not metas" do
      presence_map = %{
        "5" => %{metas: [%{name: "Dave"}, %{name: "Dave"}]},
        "7" => %{metas: [%{name: "Sam"}]}
      }

      assert Presence.watch_count(presence_map) == 2
    end

    test "is zero for an empty presence map" do
      assert Presence.watch_count(%{}) == 0
    end
  end
end
