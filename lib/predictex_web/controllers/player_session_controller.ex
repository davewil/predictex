defmodule PredictexWeb.PlayerSessionController do
  use PredictexWeb, :controller

  alias Predictex.Accounts
  alias PredictexWeb.PlayerAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "Player confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"player" => %{"token" => token} = player_params}, info) do
    case Accounts.login_player_by_magic_link(token) do
      {:ok, {player, tokens_to_disconnect}} ->
        PlayerAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> PlayerAuth.log_in_player(player, player_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/players/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"player" => player_params}, info) do
    %{"email" => email, "password" => password} = player_params

    if player = Accounts.get_player_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> PlayerAuth.log_in_player(player, player_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/players/log-in")
    end
  end

  def update_password(conn, %{"player" => player_params} = params) do
    player = conn.assigns.current_scope.player
    true = Accounts.sudo_mode?(player)
    {:ok, {_player, expired_tokens}} = Accounts.update_player_password(player, player_params)

    # disconnect all existing LiveViews with old sessions
    PlayerAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:player_return_to, ~p"/players/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> PlayerAuth.log_out_player()
  end
end
