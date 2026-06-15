defmodule PredictexWeb.PlayerLive.ConfirmationTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures

  alias Predictex.Accounts

  setup do
    %{unconfirmed_player: unconfirmed_player_fixture(), confirmed_player: player_fixture()}
  end

  describe "Confirm player" do
    test "renders confirmation page for unconfirmed player", %{
      conn: conn,
      unconfirmed_player: player
    } do
      token =
        extract_player_token(fn url ->
          Accounts.deliver_login_instructions(player, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/players/log-in/#{token}")
      assert html =~ "Confirm and stay logged in"
    end

    test "renders login page for confirmed player", %{conn: conn, confirmed_player: player} do
      token =
        extract_player_token(fn url ->
          Accounts.deliver_login_instructions(player, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/players/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Keep me logged in on this device"
    end

    test "renders login page for already logged in player", %{
      conn: conn,
      confirmed_player: player
    } do
      conn = log_in_player(conn, player)

      token =
        extract_player_token(fn url ->
          Accounts.deliver_login_instructions(player, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/players/log-in/#{token}")
      refute html =~ "Confirm my account"
      assert html =~ "Log in"
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_player: player} do
      token =
        extract_player_token(fn url ->
          Accounts.deliver_login_instructions(player, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/players/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"player" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Player confirmed successfully"

      assert Accounts.get_player!(player.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :player_token)
      assert redirected_to(conn) == ~p"/predictions"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/players/log-in/#{token}")
        |> follow_redirect(conn, ~p"/players/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed player in without changing confirmed_at", %{
      conn: conn,
      confirmed_player: player
    } do
      token =
        extract_player_token(fn url ->
          Accounts.deliver_login_instructions(player, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/players/log-in/#{token}")

      form = form(lv, "#login_form", %{"player" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Accounts.get_player!(player.id).confirmed_at == player.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/players/log-in/#{token}")
        |> follow_redirect(conn, ~p"/players/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/players/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/players/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end
end
