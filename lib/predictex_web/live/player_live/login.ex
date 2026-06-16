defmodule PredictexWeb.PlayerLive.Login do
  use PredictexWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card
        heading="Welcome back"
        sub={
          if @current_scope,
            do: "Reauthenticate to perform sensitive actions on your account.",
            else: "The group's been busy. Let's see where you stand."
        }
      >
        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/players/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
            Log in and stay logged in <span aria-hidden="true">→</span>
          </.button>
          <.button class="btn btn-primary btn-soft w-full mt-2">
            Log in only this time
          </.button>
        </.form>

        <p :if={!@current_scope} class="mt-5 text-center text-sm text-base-content/60">
          New here?
          <.link navigate={~p"/players/register"} class="font-bold text-primary hover:underline">
            Create an account
          </.link>
        </p>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:player), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "player")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
