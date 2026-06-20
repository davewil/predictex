defmodule Predictex.Replay.CacheTest do
  use Predictex.DataCase, async: false

  alias Predictex.{Capture, Repo}
  alias Predictex.Capture.Snapshot
  alias Predictex.Replay.Cache

  setup do
    start_supervised!(Cache)
    :ok
  end

  describe "frames/1" do
    test "returns [] for a match with no captures" do
      assert Cache.frames("no-such-match-cache-xyz") == []
    end

    test "returns projected frames on a miss and caches them" do
      match_id = "cache-test-match-001"

      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: ~U[2026-06-20 19:00:00Z],
          endpoint: "detail",
          url: "u",
          match_id: match_id,
          http_status: 200,
          body: %{
            "MatchStatus" => 3,
            "MatchTime" => "30'",
            "HomeTeam" => %{"Score" => 1},
            "AwayTeam" => %{"Score" => 0}
          }
        })

      frames = Cache.frames(match_id)

      assert length(frames) == 1
      assert hd(frames).live_home_goals == 1
      assert hd(frames).live_away_goals == 0
      assert hd(frames).live_minute == "30'"

      # Prove caching: delete all snapshots, second call must still return the same frames.
      Repo.delete_all(Snapshot)

      assert Cache.frames(match_id) == frames
    end
  end
end
