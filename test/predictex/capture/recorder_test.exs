defmodule Predictex.Capture.RecorderTest do
  use Predictex.DataCase, async: false
  alias Predictex.{Capture, Capture.Recorder}

  test "records a broadcast snapshot to fifa_captures" do
    start_supervised!(Recorder)
    msg = {:snapshot, 1, %{"MatchStatus" => 3}, ~U[2026-06-17 17:00:00Z], "m1", "http://u"}
    Phoenix.PubSub.broadcast(Predictex.PubSub, "fifa:snapshots", msg)

    # the GenServer handles async; wait for the row
    Process.sleep(50)

    assert [%{match_id: "m1", endpoint: "detail", http_status: 200}] =
             Capture.list_snapshots("m1")
  end
end
