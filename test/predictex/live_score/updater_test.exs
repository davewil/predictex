defmodule Predictex.LiveScore.UpdaterTest do
  use Predictex.DataCase, async: false
  alias Predictex.{Tournament, LiveScore.Updater}

  test "applies a broadcast snapshot to the fixture's live_* and broadcasts" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "x",
        team1: "A",
        team2: "B",
        round_id: r.id,
        kickoff_at: ~U[2026-06-17 17:00:00Z]
      })

    start_supervised!(Updater)
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")

    body = %{
      "MatchStatus" => 3,
      "MatchTime" => "12'",
      "HomeTeam" => %{"Score" => 1},
      "AwayTeam" => %{"Score" => 0}
    }

    Phoenix.PubSub.broadcast(
      Predictex.PubSub,
      "fifa:snapshots",
      {:snapshot, f.id, body, ~U[2026-06-17 17:12:00Z], "m1", "u"}
    )

    assert_receive {:live_update, _id}, 500
    assert %{is_live: true, live_home_goals: 1} = Tournament.get_fixture!(f.id)
  end
end
