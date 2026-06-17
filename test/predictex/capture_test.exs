defmodule Predictex.CaptureTest do
  use Predictex.DataCase, async: true
  alias Predictex.Capture

  test "record_snapshot/1 persists and list_snapshots/1 reads back in time order" do
    {:ok, _} =
      Capture.record_snapshot(%{
        captured_at: ~U[2026-06-17 17:00:00Z],
        endpoint: "detail",
        url: "u",
        match_id: "m1",
        http_status: 200,
        body: %{"MatchStatus" => 3}
      })

    assert [%{match_id: "m1", endpoint: "detail"}] = Capture.list_snapshots("m1")
  end
end
