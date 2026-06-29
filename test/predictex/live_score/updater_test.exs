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

  test "a malformed (schema-drift) snapshot does not crash the subscriber or broadcast" do
    # predictex-bl8: the bare `rescue` is gone, so resilience to a poison body now lives in the
    # decode being total. A no-op malformed snapshot (non-map team object, otherwise unchanged
    # values) must apply to nothing -> no {:live_update} -> and crucially must NOT crash the
    # GenServer (a crash of N concurrent matches could exhaust the root supervisor budget).
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "x",
        team1: "A",
        team2: "B",
        round_id: r.id,
        kickoff_at: ~U[2026-06-17 17:00:00Z],
        is_live: true,
        live_minute: "10'"
      })

    pid = start_supervised!(Updater)
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")

    # MatchStatus 3 -> is_live true (unchanged), MatchTime unchanged, both teams non-map -> nil
    # score fallback (unchanged nil). Net: no field changed, so no broadcast — and no raise.
    bad = %{"MatchStatus" => 3, "MatchTime" => "10'", "HomeTeam" => "Brazil", "AwayTeam" => nil}

    Phoenix.PubSub.broadcast(
      Predictex.PubSub,
      "fifa:snapshots",
      {:snapshot, f.id, bad, ~U[2026-06-17 17:10:00Z], "m1", "u"}
    )

    # Synchronous round-trip: get_state is handled after the snapshot in the mailbox, so its
    # return both proves the snapshot was processed AND that the subscriber did not crash
    # decoding it (a crash would make this call exit). Same pid throughout = no restart.
    assert is_map(:sys.get_state(pid))
    refute_received {:live_update, _id}
    assert Process.alive?(pid)
  end
end
