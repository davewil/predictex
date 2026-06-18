defmodule PredictexWeb.MyPredictionsLiveTest do
  # async: false because the live_buzz flag test mutates global FunWithFlags state (ETS)
  # and would race with other async tests.
  use PredictexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.{Predictions, Tournament}

  defp fixture!(round, attrs) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      team1: "Mexico",
      team2: "Poland",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  setup do
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    %{round: round}
  end

  test "redirects to login when logged out", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/players/log-in"}}} = live(conn, ~p"/predictions")
  end

  test "shows the member's pick, points and a no-pick warning", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "Dave"})

    before_kickoff =
      DateTime.utc_now() |> DateTime.add(-3601, :second) |> DateTime.truncate(:second)

    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    done = fixture!(round, %{kickoff_at: past, status: :completed, home_goals: 2, away_goals: 1})
    _open = fixture!(round, %{team1: "Brazil", team2: "Serbia", kickoff_at: future})

    {:ok, _} =
      Predictions.create_prediction(
        %{player_id: player.id, fixture_id: done.id, home_goals: 2, away_goals: 1},
        before_kickoff
      )

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    assert html =~ "My Predictions"
    assert html =~ "Mexico"
    assert html =~ "No pick imported"

    # points breakdown labels regular-scoring points as "from fixtures", not a fixture count
    # (predictex-d64 — same mislabel as the leaderboard champion card).
    assert html =~ "from fixtures"
    refute html =~ ~r/\d fixtures ·/
  end

  test "a member sees their own picks, not another player's", %{conn: conn, round: round} do
    me = player_fixture(%{display_name: "Me"})
    them = player_fixture(%{display_name: "Them"})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{kickoff_at: future})

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: them.id,
        fixture_id: f.id,
        home_goals: 4,
        away_goals: 4
      })

    {:ok, _lv, html} = conn |> log_in_player(me) |> live(~p"/predictions")
    refute html =~ "4 – 4"
  end

  test "switching round tabs shows that round's fixtures", %{conn: conn, round: round} do
    {:ok, round2} = Tournament.create_round(%{name: "Matchday 2", stage: :group, ordinal: 2})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    _f1 = fixture!(round, %{kickoff_at: future})
    _f2 = fixture!(round2, %{team1: "Japan", team2: "Germany", kickoff_at: future})
    player = player_fixture(%{display_name: "Dave"})

    {:ok, lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")
    refute html =~ "Japan"

    html = lv |> element("button", "Matchday 2") |> render_click()
    assert html =~ "Japan"
  end

  test "shows live score on the card only when the flag is on", %{conn: conn, round: round} do
    on_exit(fn -> FunWithFlags.disable(:live_buzz) end)

    player = player_fixture(%{display_name: "LiveTester"})
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    live_fx =
      fixture!(round, %{
        kickoff_at: past,
        status: :live,
        is_live: true,
        live_home_goals: 1,
        live_away_goals: 0,
        live_minute: "23'"
      })

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: live_fx.id,
        home_goals: 1,
        away_goals: 0
      })

    FunWithFlags.disable(:live_buzz)
    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")
    refute html =~ "LIVE"

    FunWithFlags.enable(:live_buzz)
    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")
    assert html =~ "LIVE"
    assert html =~ "1-0"
  end

  test "live badge links to the fixture drill-down when live_buzz is on and fixture is live",
       %{conn: conn, round: round} do
    on_exit(fn -> FunWithFlags.disable(:live_buzz) end)
    FunWithFlags.enable(:live_buzz)

    player = player_fixture(%{display_name: "CTATester"})
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    live_fx =
      fixture!(round, %{
        kickoff_at: past,
        status: :live,
        is_live: true,
        live_home_goals: 2,
        live_away_goals: 1,
        live_minute: "67'"
      })

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: live_fx.id,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    assert html =~ ~s(href="/fixtures/#{live_fx.id}")
  end

  test "live badge is not a link when fixture is not live", %{conn: conn, round: round} do
    on_exit(fn -> FunWithFlags.disable(:live_buzz) end)
    FunWithFlags.enable(:live_buzz)

    player = player_fixture(%{display_name: "NotLiveTester"})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    _fx = fixture!(round, %{kickoff_at: future, is_live: false})

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    refute html =~ ~s(href="/fixtures/)
  end
end
