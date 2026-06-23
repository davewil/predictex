defmodule Predictex.Workers.LiveScoreSyncTest do
  use Predictex.DataCase, async: true
  use Oban.Testing, repo: Predictex.Repo
  alias Predictex.Tournament
  alias Predictex.Workers.LiveScoreSync, as: Live

  defp put_fetch(fun) do
    Application.put_env(:predictex, :live_score_fetch_fun, fun)
    on_exit(fn -> Application.delete_env(:predictex, :live_score_fetch_fun) end)
  end

  defp window_fixture do
    fixture(%{external_ref: "x", fifa_match_id: "400021502"})
  end

  defp fixture(attrs) do
    # Share one round per test (ordinal is unique + must be 1..8) so a test can
    # create several fixtures without colliding.
    round =
      Tournament.get_round_by_ordinal(1) ||
        (
          {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})
          r
        )

    {:ok, f} =
      Tournament.create_fixture(
        Map.merge(
          %{
            external_ref: "x",
            team1: "A",
            team2: "B",
            round_id: round.id,
            # kickoff 1 min ago: inside the capture window by default
            kickoff_at: DateTime.add(DateTime.utc_now(), -60)
          },
          attrs
        )
      )

    f
  end

  defp minutes_ago(m), do: DateTime.add(DateTime.utc_now(), -m * 60)

  test "publishes a snapshot per in-window fixture and reschedules" do
    f = window_fixture()
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")

    put_fetch(fn _url ->
      {:ok, 200,
       %{
         "MatchStatus" => 3,
         "HomeTeam" => %{"Score" => 1},
         "AwayTeam" => %{"Score" => 0},
         "MatchTime" => "5'"
       }}
    end)

    assert :ok = perform_job(Live, %{})
    assert_received {:snapshot, fixture_id, %{"MatchStatus" => 3}, _at, "400021502", _url}
    assert fixture_id == f.id
    assert_enqueued(worker: Live)
  end

  test "captures the pre-kickoff window (kickoff in 5 min)" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "y",
        team1: "A",
        team2: "B",
        round_id: r.id,
        kickoff_at: DateTime.add(DateTime.utc_now(), 300),
        fifa_match_id: "999"
      })

    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    put_fetch(fn _url -> {:ok, 200, %{"MatchStatus" => 1}} end)

    assert :ok = perform_job(Live, %{})
    assert_received {:snapshot, fixture_id, _body, _at, "999", _url}
    assert fixture_id == f.id
  end

  test "is unique so the cron trigger can't stack a duplicate" do
    assert {:ok, _} = Oban.insert(Live.new(%{}, schedule_in: 30))
    # a second identical insert within the unique window is deduped
    assert {:ok, job2} = Oban.insert(Live.new(%{}, schedule_in: 30))
    assert job2.conflict?
  end

  test "no in-window fixtures → no broadcast, no reschedule" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, _} =
      Tournament.create_fixture(%{
        external_ref: "z",
        team1: "A",
        team2: "B",
        round_id: r.id,
        kickoff_at: DateTime.add(DateTime.utc_now(), 3600),
        fifa_match_id: "111"
      })

    assert :ok = perform_job(Live, %{})
    refute_enqueued(worker: Live)
  end

  test "window covers a fixture +180min after kickoff (knockout ET/penalties stay live)" do
    f = fixture(%{external_ref: "et", kickoff_at: minutes_ago(180), fifa_match_id: "555"})
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    put_fetch(fn _url -> {:ok, 200, %{"MatchStatus" => 3}} end)

    assert :ok = perform_job(Live, %{})
    assert_received {:snapshot, fixture_id, _body, _at, "555", _url}
    assert fixture_id == f.id
  end

  test "keeps capturing a still-live fixture past the 210min window (weather-delayed match)" do
    # France v Iraq 2026-06-22: a ~2h half-time weather suspension pushed the match's real
    # end past kickoff+210min. The match was still in play (is_live, MatchStatus 3) when the
    # old fixed window dropped it — losing the final frames. Capture must follow liveness.
    f =
      fixture(%{
        external_ref: "weather",
        kickoff_at: minutes_ago(250),
        fifa_match_id: "492",
        is_live: true,
        status: :scheduled
      })

    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    put_fetch(fn _url -> {:ok, 200, %{"MatchStatus" => 3}} end)

    assert :ok = perform_job(Live, %{})
    assert_received {:snapshot, fixture_id, _body, _at, "492", _url}
    assert fixture_id == f.id
    assert_enqueued(worker: Live)
  end

  test "does not force-clear a still-live fixture past the 210min window (weather break)" do
    f =
      fixture(%{
        external_ref: "weather2",
        kickoff_at: minutes_ago(250),
        fifa_match_id: "492",
        is_live: true,
        status: :scheduled
      })

    put_fetch(fn _url -> {:ok, 200, %{"MatchStatus" => 3}} end)

    assert :ok = perform_job(Live, %{})
    assert %{is_live: true} = Tournament.get_fixture!(f.id)
  end

  test "a finished fixture past the window is not re-captured (is_live is the only extension)" do
    fixture(%{
      external_ref: "done-old",
      kickoff_at: minutes_ago(250),
      fifa_match_id: "493",
      is_live: false,
      status: :completed
    })

    Phoenix.PubSub.subscribe(Predictex.PubSub, "fifa:snapshots")
    assert :ok = perform_job(Live, %{})
    refute_received {:snapshot, _, _, _, "493", _}
    refute_enqueued(worker: Live)
  end

  test "clears a :completed fixture's is_live while the chain runs for a concurrent live match (d17 fast-path)" do
    done =
      fixture(%{
        external_ref: "done",
        kickoff_at: minutes_ago(100),
        fifa_match_id: "777",
        is_live: true,
        status: :completed
      })

    # a concurrent, genuinely-live match keeps the self-reschedule chain alive
    _live =
      fixture(%{
        external_ref: "ongoing",
        kickoff_at: minutes_ago(60),
        fifa_match_id: "778",
        is_live: true,
        status: :scheduled
      })

    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{done.id}")
    put_fetch(fn _url -> {:ok, 200, %{"MatchStatus" => 3}} end)

    assert :ok = perform_job(Live, %{})
    assert_received {:live_update, fixture_id}
    assert fixture_id == done.id
    assert %{is_live: false} = Tournament.get_fixture!(done.id)
    # chain still alive on account of the ongoing match — the sweep cleared independently
    assert_enqueued(worker: Live)
  end

  test "clears is_live for a stuck fixture past the abandon backstop (double feed failure)" do
    f =
      fixture(%{
        external_ref: "stuck",
        kickoff_at: minutes_ago(370),
        is_live: true,
        status: :scheduled
      })

    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")

    assert :ok = perform_job(Live, %{})
    assert_received {:live_update, fixture_id}
    assert fixture_id == f.id
    assert %{is_live: false} = Tournament.get_fixture!(f.id)
  end

  test "does not clear a genuinely-live in-window fixture" do
    f =
      fixture(%{
        external_ref: "livegame",
        kickoff_at: minutes_ago(60),
        fifa_match_id: "888",
        is_live: true,
        status: :scheduled
      })

    put_fetch(fn _url -> {:ok, 200, %{"MatchStatus" => 3}} end)

    assert :ok = perform_job(Live, %{})
    assert %{is_live: true} = Tournament.get_fixture!(f.id)
  end

  test "a swept fixture is not re-broadcast on the next tick" do
    f =
      fixture(%{
        external_ref: "twice",
        kickoff_at: minutes_ago(370),
        is_live: true,
        status: :scheduled
      })

    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")

    assert :ok = perform_job(Live, %{})
    assert_received {:live_update, _}

    assert :ok = perform_job(Live, %{})
    refute_received {:live_update, _}
  end
end
