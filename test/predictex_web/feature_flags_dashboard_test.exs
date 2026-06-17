defmodule PredictexWeb.FeatureFlagsDashboardTest do
  # async: false — the admin test enables a flag (global FunWithFlags ETS state).
  use PredictexWeb.ConnCase, async: false

  import Predictex.AccountsFixtures

  @path "/admin/feature-flags"

  setup do
    on_exit(fn -> FunWithFlags.disable(:live_buzz) end)
    :ok
  end

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
    conn = conn |> log_in_player(player) |> post("#{@path}/flags/live_buzz/boolean")

    # Blocked by the admin pipeline before reaching the UI router.
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "admin"
    refute FunWithFlags.enabled?(:live_buzz)
  end

  test "admins can load the flag listing and see persisted flags", %{conn: conn} do
    admin = admin_player_fixture(%{display_name: "Boss"})
    FunWithFlags.enable(:live_buzz)

    conn = conn |> log_in_player(admin) |> get("#{@path}/flags")

    body = html_response(conn, 200)
    assert body =~ "live_buzz"
  end
end
