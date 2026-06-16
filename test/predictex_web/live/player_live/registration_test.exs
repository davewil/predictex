defmodule PredictexWeb.PlayerLive.RegistrationTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/players/register")

      assert html =~ "Join the league"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_player(player_fixture())
        |> live(~p"/players/register")
        |> follow_redirect(conn, ~p"/predictions")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/players/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(player: %{"email" => "with spaces"})

      assert result =~ "Join the league"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register player" do
    test "creates account and logs the player in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/players/register")

      email = unique_player_email()

      form =
        form(lv, "#registration_form",
          player: valid_player_attributes(email: email) |> Map.put(:invite_code, "test-code")
        )

      render_submit(form)

      # Registration auto-confirms and sets a password, so the LiveView triggers
      # the form action to the session controller, which logs the player in.
      conn = follow_trigger_action(form, conn)

      assert get_session(conn, :player_token)
      assert redirected_to(conn) == ~p"/predictions"

      assert %Predictex.Accounts.Player{} = player = Predictex.Accounts.get_player_by_email(email)
      assert player.confirmed_at
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/players/register")

      player = player_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          player: %{"email" => player.email, "invite_code" => "test-code"}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "rejects registration with an invalid invite code", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/players/register")

      email = unique_player_email()

      result =
        lv
        |> form("#registration_form",
          player: valid_player_attributes(email: email) |> Map.put(:invite_code, "wrong")
        )
        |> render_submit()

      assert result =~ "Invalid league invite code."
      assert Predictex.Accounts.get_player_by_email(email) == nil
    end

    test "rejects registration when invite code is missing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/players/register")

      email = unique_player_email()

      result =
        lv
        |> form("#registration_form",
          player: valid_player_attributes(email: email)
        )
        |> render_submit()

      assert result =~ "Invalid league invite code."
      assert Predictex.Accounts.get_player_by_email(email) == nil
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/players/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/players/log-in")

      assert login_html =~ "Log in"
    end
  end
end
