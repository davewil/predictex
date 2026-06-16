defmodule PredictexWeb.PlayerLive.LoginTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/players/log-in")

      assert html =~ "Log in"
      assert html =~ "Create an account"
      refute html =~ "Log in with email"
    end
  end

  describe "player login - password" do
    test "redirects if player logs in with valid credentials", %{conn: conn} do
      player = player_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/players/log-in")

      form =
        form(lv, "#login_form_password",
          player: %{email: player.email, password: valid_player_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/predictions"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/players/log-in")

      form =
        form(lv, "#login_form_password", player: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/players/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/players/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Create an account")
        |> render_click()
        |> follow_redirect(conn, ~p"/players/register")

      assert login_html =~ "Join the league"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      player = player_fixture()
      %{player: player, conn: log_in_player(conn, player)}
    end

    test "shows login page with email filled in", %{conn: conn, player: player} do
      {:ok, _lv, html} = live(conn, ~p"/players/log-in")

      assert html =~ "Reauthenticate to perform sensitive actions"
      refute html =~ "Register"
      refute html =~ "Log in with email"

      assert html =~
               ~s(<input type="email" name="player[email]" id="login_form_password_email" value="#{player.email}")
    end
  end
end
