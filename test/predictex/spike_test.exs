defmodule Predictex.SpikeTest do
  use Predictex.DataCase, async: true

  import ExUnit.CaptureIO

  alias Predictex.Spike

  @t0 ~U[2026-06-17 16:50:00Z]

  # Insert via the production write path (record_capture/1), with FIFA-shaped bodies.
  defp cap(match_id, endpoint, body, offset) do
    {:ok, c} =
      Spike.record_capture(%{
        captured_at: DateTime.add(@t0, offset),
        endpoint: endpoint,
        url: "http://x/#{endpoint}",
        match_id: match_id,
        http_status: 200,
        error: nil,
        body: body
      })

    c
  end

  defp detail(status, period, time, home, away, goals \\ []) do
    %{
      "MatchStatus" => status,
      "Period" => period,
      "MatchTime" => time,
      "HomeTeam" => %{
        "Score" => home,
        "Players" => [
          %{
            "IdPlayer" => "p1",
            "PlayerName" => [%{"Locale" => "en-GB", "Description" => "A SCORER"}]
          }
        ],
        "Goals" => goals
      },
      "AwayTeam" => %{"Score" => away, "Players" => [], "Goals" => []}
    }
  end

  test "analyze/1 surfaces transitions, statuses seen, populated now, and named goals" do
    mid = "m1"
    goal = %{"IdPlayer" => "p1", "Minute" => "23'", "Type" => 2, "IdTeam" => "home1"}

    caps = [
      cap(mid, "detail", detail(1, 0, "0'", nil, nil), 0),
      cap(mid, "now", %{"Results" => []}, 0),
      cap(mid, "detail", detail(3, 3, "23'", 1, 0, [goal]), 600),
      cap(mid, "now", %{"Results" => [%{"IdMatch" => mid, "MatchStatus" => 3}]}, 600),
      cap(mid, "detail", detail(0, 10, "94'", 2, 1, [goal]), 7000)
    ]

    r = Spike.analyze(caps)

    assert r.match_id == mid
    assert r.by_endpoint == %{"detail" => 3, "now" => 2}
    assert r.errors == 0
    assert r.statuses_seen == [0, 1, 3]

    # One row per status/score change: pre-match, live 1-0, finished 2-1.
    assert Enum.map(r.transitions, &{&1.status, &1.home, &1.away}) == [
             {1, nil, nil},
             {3, 1, 0},
             {0, 2, 1}
           ]

    assert r.now_first_populated.count == 1
    assert "MatchStatus" in r.now_first_populated.entry_keys

    assert %{side: "home", type: "goal", scorer: "A SCORER"} = hd(r.goals)
  end

  test "now_first_populated is nil when /now never carried a live match" do
    mid = "m2"
    cap(mid, "now", %{"Results" => []}, 0)
    cap(mid, "detail", detail(1, 0, "0'", nil, nil), 0)

    assert Spike.analyze(Spike.list_captures(mid)).now_first_populated == nil
  end

  test "summary/1 prints a report and returns the analysis map" do
    mid = "m3"
    cap(mid, "detail", detail(0, 10, "90'", 1, 0), 0)

    out = capture_io(fn -> assert %{statuses_seen: [0]} = Spike.summary(mid) end)
    assert out =~ "match #{mid}"
    assert out =~ "status / score transitions"
  end
end
