defmodule Predictex.ReplayTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Capture, Replay}

  describe "frames/1" do
    test "returns [] for a match with no captures" do
      assert Replay.frames("no-such-match-xyz") == []
    end

    test "decodes detail bodies in captured_at order and skips non-detail snapshots" do
      # Insert out of time order — frame B is older but inserted second
      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: ~U[2026-06-20 20:00:00Z],
          endpoint: "detail",
          url: "u",
          match_id: "replay-order-test",
          http_status: 200,
          body: %{
            "MatchStatus" => 3,
            "MatchTime" => "45'",
            "HomeTeam" => %{"Score" => 1},
            "AwayTeam" => %{"Score" => 0}
          }
        })

      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: ~U[2026-06-20 19:00:00Z],
          endpoint: "detail",
          url: "u",
          match_id: "replay-order-test",
          http_status: 200,
          body: %{
            "MatchStatus" => 3,
            "MatchTime" => "10'",
            "HomeTeam" => %{"Score" => 0},
            "AwayTeam" => %{"Score" => 0}
          }
        })

      # A "now" snapshot that should be skipped
      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: ~U[2026-06-20 19:30:00Z],
          endpoint: "now",
          url: "u",
          match_id: "replay-order-test",
          http_status: 200,
          body: %{"Results" => [%{"IdMatch" => "replay-order-test"}]}
        })

      [frame1, frame2] = Replay.frames("replay-order-test")

      # Frame 1 is the earlier capture (19:00) — 0-0, minute 10'
      assert frame1.live_home_goals == 0
      assert frame1.live_away_goals == 0
      assert frame1.live_minute == "10'"

      # Frame 2 is the later capture (20:00) — 1-0, minute 45'
      assert frame2.live_home_goals == 1
      assert frame2.live_away_goals == 0
      assert frame2.live_minute == "45'"

      # Exactly 2 frames — the "now" snapshot is absent
      assert length(Replay.frames("replay-order-test")) == 2
    end

    test "carries the previous score forward when a later body has nil scores" do
      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: ~U[2026-06-20 19:00:00Z],
          endpoint: "detail",
          url: "u",
          match_id: "replay-carry-test",
          http_status: 200,
          body: %{
            "MatchStatus" => 3,
            "MatchTime" => "60'",
            "HomeTeam" => %{"Score" => 2},
            "AwayTeam" => %{"Score" => 1}
          }
        })

      # Second body has nil scores (no Score keys) — should inherit 2-1
      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: ~U[2026-06-20 19:01:00Z],
          endpoint: "detail",
          url: "u",
          match_id: "replay-carry-test",
          http_status: 200,
          body: %{
            "MatchStatus" => 3,
            "MatchTime" => "61'"
          }
        })

      [_frame1, frame2] = Replay.frames("replay-carry-test")

      assert frame2.live_home_goals == 2
      assert frame2.live_away_goals == 1
      assert frame2.live_minute == "61'"
    end
  end

  describe "tick_delay_ms/1 (adaptive pacing)" do
    test "lingers on a score change so the buzz is readable" do
      assert Replay.tick_delay_ms(true) > Replay.tick_delay_ms(false)
    end

    test "both delays are positive" do
      assert Replay.tick_delay_ms(true) > 0
      assert Replay.tick_delay_ms(false) > 0
    end
  end
end
