defmodule PredictexWeb.PlayerSessionControllerTest do
  use PredictexWeb.ConnCase, async: true

  import Predictex.AccountsFixtures
  alias Predictex.Accounts

  setup do
    %{unconfirmed_player: unconfirmed_player_fixture(), player: player_fixture()}
  end

  describe "POST /players/log-in - email and password" do
    test "logs the player in", %{conn: conn, player: player} do
      player = set_password(player)

      conn =
        post(conn, ~p"/players/log-in", %{
          "player" => %{"email" => player.email, "password" => valid_player_password()}
        })

      assert get_session(conn, :player_token)
      assert redirected_to(conn) == ~p"/predictions"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ player.email
      assert response =~ ~p"/players/settings"
      assert response =~ ~p"/players/log-out"
    end

    test "logs the player in with remember me", %{conn: conn, player: player} do
      player = set_password(player)

      conn =
        post(conn, ~p"/players/log-in", %{
          "player" => %{
            "email" => player.email,
            "password" => valid_player_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_predictex_web_player_remember_me"]
      assert redirected_to(conn) == ~p"/predictions"
    end

    test "logs the player in with return to", %{conn: conn, player: player} do
      player = set_password(player)

      conn =
        conn
        |> init_test_session(player_return_to: "/foo/bar")
        |> post(~p"/players/log-in", %{
          "player" => %{
            "email" => player.email,
            "password" => valid_player_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, player: player} do
      conn =
        post(conn, ~p"/players/log-in?mode=password", %{
          "player" => %{"email" => player.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/players/log-in"
    end
  end

  describe "POST /players/log-in - magic link" do
    test "logs the player in", %{conn: conn, player: player} do
      {token, _hashed_token} = generate_player_magic_link_token(player)

      conn =
        post(conn, ~p"/players/log-in", %{
          "player" => %{"token" => token}
        })

      assert get_session(conn, :player_token)
      assert redirected_to(conn) == ~p"/predictions"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ player.email
      assert response =~ ~p"/players/settings"
      assert response =~ ~p"/players/log-out"
    end

    test "confirms unconfirmed player", %{conn: conn, unconfirmed_player: player} do
      {token, _hashed_token} = generate_player_magic_link_token(player)
      refute player.confirmed_at

      conn =
        post(conn, ~p"/players/log-in", %{
          "player" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :player_token)
      assert redirected_to(conn) == ~p"/predictions"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Player confirmed successfully."

      assert Accounts.get_player!(player.id).confirmed_at

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ player.email
      assert response =~ ~p"/players/settings"
      assert response =~ ~p"/players/log-out"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/players/log-in", %{
          "player" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/players/log-in"
    end
  end

  describe "DELETE /players/log-out" do
    test "logs the player out", %{conn: conn, player: player} do
      conn = conn |> log_in_player(player) |> delete(~p"/players/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :player_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the player is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/players/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :player_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
