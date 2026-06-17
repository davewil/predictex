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
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})
    # kickoff 1 min ago: inside [kickoff-10min, kickoff+150min]
    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "x",
        team1: "A",
        team2: "B",
        round_id: r.id,
        kickoff_at: DateTime.add(DateTime.utc_now(), -60),
        fifa_match_id: "400021502"
      })

    f
  end

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
end
