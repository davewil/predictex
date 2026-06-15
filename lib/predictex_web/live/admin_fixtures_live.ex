defmodule PredictexWeb.AdminFixturesLive do
  @moduledoc "Admin fixtures: sync, result override, cohort %. Built in Phase 6."
  use PredictexWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Fixtures")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminComponents.admin_nav active={:fixtures} />
      <p>Fixtures — coming in Phase 6.</p>
    </Layouts.app>
    """
  end
end
