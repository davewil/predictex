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
      <h1 class="text-xl font-semibold mb-4">Admin console</h1>
      <ul class="menu bg-base-200 rounded-box w-full">
        <li>
          <.link navigate={~p"/admin/predictions"}>Enter predictions ({@player_count} players)</.link>
        </li>
        <li>
          <.link navigate={~p"/admin/fixtures"}>Fixtures &amp; results ({@fixture_count} fixtures)</.link>
        </li>
        <li><.link navigate={~p"/admin/players"}>Players</.link></li>
      </ul>
    </Layouts.app>
    """
  end
end
