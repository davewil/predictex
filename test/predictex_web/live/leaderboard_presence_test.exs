defmodule PredictexWeb.LeaderboardPresenceTest do
  # async: false — the "watching:live" presence topic is global (cross-match), so this
  # must not run concurrently with the async fixture_live tests that also join it.
  use PredictexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.Tournament

  defp live_fixture! do
    {:ok, round} = Tournament.create_round(%{name: "Final", stage: :knockout, ordinal: 1})
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "live-#{System.unique_integer([:positive])}",
        team1: "England",
        team2: "France",
        round_id: round.id,
        kickoff_at: past,
        status: :live,
        is_live: true,
        live_home_goals: 1,
        live_away_goals: 0,
        live_minute: "45'"
      })

    fx
  end

  test "leaderboard shows the count of players watching a live match, updating live" do
    watcher = player_fixture(%{display_name: "Watcher"})
    fx = live_fixture!()

    # Synchronise deterministically on the watcher joining the live topic.
    Phoenix.PubSub.subscribe(Predictex.PubSub, "watching:live")

    # Nobody watching yet → no live-watch badge.
    {:ok, board, html} = live(build_conn(), ~p"/")
    refute html =~ "watching live"

    # A viewer opens the live fixture → joins "watching:live".
    {:ok, viewer, _} = build_conn() |> log_in_player(watcher) |> live(~p"/fixtures/#{fx.id}")
    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}

    # The leaderboard reflects it with no refresh.
    assert render(board) =~ "1 watching live"

    # Close path: the viewer leaves → the count drops to 0 and the badge disappears
    # (auto-untrack on socket DOWN, no manual cleanup).
    Process.unlink(viewer.pid)
    GenServer.stop(viewer.pid)
    assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}

    refute render(board) =~ "watching live"
  end
end
