defmodule Predictex.CaptureTest do
  use Predictex.DataCase, async: true
  alias Predictex.Capture

  describe "goal_events/1" do
    test "decodes FIFA Goals to the unified shape (Type 1/2/3, side by array, scorer via Players)" do
      body = %{
        "HomeTeam" => %{
          "Players" => [%{"IdPlayer" => "p1", "PlayerName" => [%{"Description" => "Salah"}]}],
          "Goals" => [%{"IdPlayer" => "p1", "Minute" => "16'", "Type" => 1}]
        },
        "AwayTeam" => %{
          "Players" => [%{"IdPlayer" => "p2", "PlayerName" => [%{"Description" => "Lukaku"}]}],
          "Goals" => [%{"IdPlayer" => "p2", "Minute" => "73'", "Type" => 2}]
        }
      }

      assert [
               %{side: :home, type: :penalty, player: "Salah", minute: "16"},
               %{side: :away, type: :regular, player: "Lukaku", minute: "73"}
             ] =
               Predictex.Capture.goal_events(body)
    end

    test "a body with no goals yields []" do
      assert Predictex.Capture.goal_events(%{}) == []
    end
  end

  describe "latest_detail_body/1" do
    test "returns the body of the most recent detail snapshot" do
      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: ~U[2026-06-17 17:00:00Z],
          endpoint: "detail",
          url: "u",
          match_id: "m99",
          http_status: 200,
          body: %{"old" => true}
        })

      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: ~U[2026-06-17 18:00:00Z],
          endpoint: "detail",
          url: "u",
          match_id: "m99",
          http_status: 200,
          body: %{"latest" => true}
        })

      assert %{"latest" => true} = Capture.latest_detail_body("m99")
    end

    test "returns nil when no detail snapshot exists" do
      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: ~U[2026-06-17 17:00:00Z],
          endpoint: "now",
          url: "u",
          match_id: "m100",
          http_status: 200,
          body: %{"some" => "data"}
        })

      assert is_nil(Capture.latest_detail_body("m100"))
    end

    test "returns nil when match has no snapshots at all" do
      assert is_nil(Capture.latest_detail_body("no-such-match"))
    end
  end

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
