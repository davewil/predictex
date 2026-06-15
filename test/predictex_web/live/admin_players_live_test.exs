defmodule PredictexWeb.AdminPlayersLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.Accounts

  setup %{conn: conn} do
    admin = admin_player_fixture()
    %{conn: log_in_player(conn, admin)}
  end

  test "lists players and promotes one to admin", %{conn: conn} do
    member = player_fixture(%{display_name: "Member"})
    {:ok, lv, html} = live(conn, ~p"/admin/players")

    assert html =~ "Member"

    lv |> element("button[phx-value-id='#{member.id}']", "Make admin") |> render_click()

    assert Accounts.get_player!(member.id).is_admin
  end
end
