defmodule Predictex.Workers.LiveScoreSyncTest do
  use Predictex.DataCase, async: true
  use Oban.Testing, repo: Predictex.Repo

  alias Predictex.Tournament
  alias Predictex.Workers.LiveScoreSync, as: Live

  defp put_fetch(fun) do
    Application.put_env(:predictex, :live_score_fetch_fun, fun)
    on_exit(fn -> Application.delete_env(:predictex, :live_score_fetch_fun) end)
  end

  defp live_fixture do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "x",
        team1: "Portugal",
        team2: "Congo DR",
        round_id: r.id,
        kickoff_at: DateTime.add(DateTime.utc_now(), -600),
        fifa_match_id: "400021502"
      })

    f
  end

  test "writes live_* + is_live and broadcasts when the match is in play" do
    f = live_fixture()
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")

    put_fetch(fn _url ->
      {:ok, 200,
       %{
         "MatchStatus" => 3,
         "MatchTime" => "23'",
         "HomeTeam" => %{"Score" => 1},
         "AwayTeam" => %{"Score" => 0}
       }}
    end)

    assert :ok = perform_job(Live, %{"window_min" => 150, "interval" => 30})

    f = Tournament.get_fixture!(f.id)

    assert f.is_live and f.live_home_goals == 1 and f.live_away_goals == 0 and
             f.live_minute == "23'"

    assert_received {:live_update, _id}
    assert_enqueued(worker: Live)
  end

  test "clears is_live when the match is finished (MatchStatus 0)" do
    f = live_fixture()

    {:ok, _} =
      Tournament.update_fixture(f, %{is_live: true, live_home_goals: 1, live_away_goals: 0})

    put_fetch(fn _url ->
      {:ok, 200,
       %{
         "MatchStatus" => 0,
         "MatchTime" => "94'",
         "HomeTeam" => %{"Score" => 2},
         "AwayTeam" => %{"Score" => 1}
       }}
    end)

    assert :ok = perform_job(Live, %{"window_min" => 150, "interval" => 30})
    refute Tournament.get_fixture!(f.id).is_live
    # fixture is still inside the 150-min polling window, so the job reschedules
    assert_enqueued(worker: Live)
  end
end
