defmodule PredictexWeb.PlayerLive.Settings do
  use PredictexWeb, :live_view

  on_mount {PredictexWeb.PlayerAuth, :require_sudo_mode}

  alias Predictex.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_player_email(socket.assigns.current_scope.player, token) do
        {:ok, _player} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/players/settings")}
  end

  def mount(_params, _session, socket) do
    player = socket.assigns.current_scope.player
    email_changeset = Accounts.change_player_email(player, %{}, validate_unique: false)
    password_changeset = Accounts.change_player_password(player, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, player.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"player" => player_params} = params

    email_form =
      socket.assigns.current_scope.player
      |> Accounts.change_player_email(player_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"player" => player_params} = params
    player = socket.assigns.current_scope.player
    true = Accounts.sudo_mode?(player)

    case Accounts.change_player_email(player, player_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_player_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          player.email,
          &url(~p"/players/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"player" => player_params} = params

    password_form =
      socket.assigns.current_scope.player
      |> Accounts.change_player_password(player_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"player" => player_params} = params
    player = socket.assigns.current_scope.player
    true = Accounts.sudo_mode?(player)

    case Accounts.change_player_password(player, player_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
