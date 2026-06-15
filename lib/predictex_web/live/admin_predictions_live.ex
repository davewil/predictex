defmodule PredictexWeb.AdminPredictionsLive do
  @moduledoc "Admin prediction entry (by player / by fixture). Built in Phase 4."
  use PredictexWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Predictions")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminLive.admin_nav active={:predictions} />
      <p>Prediction entry — coming in Phase 4.</p>
    </Layouts.app>
    """
  end
end
