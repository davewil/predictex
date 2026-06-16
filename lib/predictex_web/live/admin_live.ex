defmodule PredictexWeb.AdminLive do
  @moduledoc "Admin console landing: section navigation and at-a-glance counts."
  use PredictexWeb, :live_view

  alias Predictex.{Accounts, Tournament}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:player_count, Accounts.count_players())
     |> assign(:fixture_count, Tournament.count_fixtures())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminComponents.admin_nav active={:home} />

      <div class="mb-5 flex flex-wrap gap-x-5 gap-y-1">
        <PredictexWeb.AdminComponents.admin_stat label="players" value={@player_count} />
        <PredictexWeb.AdminComponents.admin_stat label="fixtures" value={@fixture_count} />
      </div>

      <div class="grid gap-3 sm:grid-cols-3">
        <.link
          navigate={~p"/admin/predictions"}
          class="rounded-box border border-base-300 bg-base-100 p-4 transition-colors hover:border-primary/40 hover:bg-base-200"
        >
          <div class="font-bold">Enter predictions</div>
          <div class="text-xs text-base-content/60">By player or by fixture, from screenshots</div>
        </.link>
        <.link
          navigate={~p"/admin/fixtures"}
          class="rounded-box border border-base-300 bg-base-100 p-4 transition-colors hover:border-primary/40 hover:bg-base-200"
        >
          <div class="font-bold">Fixtures &amp; results</div>
          <div class="text-xs text-base-content/60">Sync results, set cohort %</div>
        </.link>
        <.link
          navigate={~p"/admin/players"}
          class="rounded-box border border-base-300 bg-base-100 p-4 transition-colors hover:border-primary/40 hover:bg-base-200"
        >
          <div class="font-bold">Players</div>
          <div class="text-xs text-base-content/60">Roles &amp; admin promotion</div>
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
