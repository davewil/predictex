defmodule PredictexWeb.PlayerLive.Confirmation do
  use PredictexWeb, :live_view

  alias Predictex.Accounts

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if player = Accounts.get_player_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "player")

      {:ok, assign(socket, player: player, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/players/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"player" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "player"), trigger_submit: true)}
  end
end
