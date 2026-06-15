defmodule PredictexWeb.AdminPlayersLive do
  @moduledoc "Admin player management: list + promote. Built in Phase 7."
  use PredictexWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Players")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminComponents.admin_nav active={:players} />
      <p>Players — coming in Phase 7.</p>
    </Layouts.app>
    """
  end
end
