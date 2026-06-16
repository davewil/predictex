defmodule PredictexWeb.PlayerLive.Registration do
  use PredictexWeb, :live_view

  alias Predictex.Accounts
  alias Predictex.Accounts.Player

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card heading="Join the league" sub="Pick a name worth seeing at the top of the table.">
        <.form
          for={@form}
          id="registration_form"
          action={~p"/players/log-in"}
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@form[:display_name]}
            type="text"
            label="Display name"
            autocomplete="nickname"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
          />

          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
          />

          <.input
            field={@form[:invite_code]}
            type="text"
            label="League invite code"
            class="font-score tracking-wide text-accent"
            required
          />
          <p class="mb-2 text-[11px] text-base-content/55">🔑 Ask the group admin for the code.</p>

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>

        <p class="mt-5 text-center text-sm text-base-content/60">
          Already playing?
          <.link navigate={~p"/players/log-in"} class="font-bold text-primary hover:underline">
            Log in
          </.link>
        </p>
      </.auth_card>
    </Layouts.app>
    """
  end

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
