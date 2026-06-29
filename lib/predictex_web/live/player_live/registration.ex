defmodule PredictexWeb.PlayerLive.Registration do
  use PredictexWeb, :live_view

  alias Predictex.Accounts
  alias Predictex.Accounts.Player

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{player: player}}} = socket)
      when not is_nil(player) do
    {:ok, redirect(socket, to: PredictexWeb.PlayerAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_player_registration(%Player{})

    {:ok, assign_form(socket, changeset) |> assign(trigger_submit: false)}
  end

  @impl true
  def handle_event("save", %{"player" => player_params}, socket) do
    if Predictex.Accounts.Invite.valid?(player_params["invite_code"]) do
      case Accounts.register_player(player_params) do
        {:ok, _player} ->
          # Player is auto-confirmed and has a password, so hand off to the session
          # controller to log them in immediately. The DOM form still carries the
          # plaintext password, which the controller re-verifies before logging in.
          {:noreply, assign(socket, trigger_submit: true)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Invalid league invite code.")
       |> assign(check_errors: true)}
    end
  end

  def handle_event("validate", %{"player" => player_params}, socket) do
    changeset = Accounts.change_player_registration(%Player{}, player_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "player")
    assign(socket, form: form)
  end
end
