defmodule PredictexWeb.AdminLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures

  test "redirects a logged-out visitor to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/players/log-in"}}} = live(conn, ~p"/admin")
  end

  test "redirects a non-admin player to /", %{conn: conn} do
    player = player_fixture()
    assert {:error, {:redirect, %{to: "/"}}} = conn |> log_in_player(player) |> live(~p"/admin")
  end

  test "an admin sees the console landing with section links", %{conn: conn} do
    admin = admin_player_fixture()
    {:ok, _lv, html} = conn |> log_in_player(admin) |> live(~p"/admin")

    assert html =~ "Admin"
    assert html =~ ~p"/admin/predictions"
    assert html =~ ~p"/admin/fixtures"
    assert html =~ ~p"/admin/players"
  end
end
