defmodule PredictexWeb.AdminPlayersLive do
  @moduledoc "Admin player management: list players and promote to admin."
  use PredictexWeb, :live_view

  alias Predictex.Accounts
  alias PredictexWeb.AdminWriteResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Players") |> load_players()}
  end

  defp load_players(socket), do: assign(socket, :players, Accounts.list_players())

  @impl true
  def handle_event("promote", %{"id" => id}, socket) do
    AdminWriteResult.handle(
      socket,
      Accounts.set_player_admin(String.to_integer(id), true),
      &load_players/1,
      "Promoted to admin.",
      "Could not promote player."
    )
  end
end
