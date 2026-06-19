defmodule PredictexWeb.FeatureFlagsDashboardTest do
  # Covers the admin-gated FunWithFlags dashboard route — the dark-ship mechanism, retained
  # for future flags even though live_buzz was contracted away. async: false retained pending
  # a separate async-safety review (predictex-uhf follow-up).
  use PredictexWeb.ConnCase, async: false

  import Predictex.AccountsFixtures

  @path "/admin/feature-flags"

  test "logged-out visitors are redirected to the login page", %{conn: conn} do
    conn = get(conn, @path)
    assert redirected_to(conn) == ~p"/players/log-in"
  end

  test "authenticated non-admins are redirected to the leaderboard", %{conn: conn} do
    player = player_fixture(%{display_name: "Reg"})
    conn = conn |> log_in_player(player) |> get(@path)

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "admin"
  end

  test "the dashboard root redirects admins to the namespaced flag listing", %{conn: conn} do
    admin = admin_player_fixture(%{display_name: "Boss"})
    conn = conn |> log_in_player(admin) |> get(@path)

    # The UI's index redirects to its listing; the target proves the namespace is wired.
    assert redirected_to(conn) == "#{@path}/flags"
  end

  test "non-admins are blocked from flag-mutation routes (not just GETs)", %{conn: conn} do
    player = player_fixture(%{display_name: "Reg"})
    conn = conn |> log_in_player(player) |> post("#{@path}/flags/example_flag/boolean")

    # Blocked by the admin pipeline before reaching the UI router.
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "admin"
  end

  test "admins can load the flag listing", %{conn: conn} do
    admin = admin_player_fixture(%{display_name: "Boss"})

    conn = conn |> log_in_player(admin) |> get("#{@path}/flags")

    # The admin-only listing renders (200). No flags are persisted by default after
    # contracting live_buzz, so we assert the route is reachable, not any specific flag.
    assert html_response(conn, 200)
  end
end
