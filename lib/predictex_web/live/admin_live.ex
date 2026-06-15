defmodule PredictexWeb.AdminLive do
  @moduledoc "Admin console landing: section navigation and at-a-glance counts."
  use PredictexWeb, :live_view

  alias Predictex.{Accounts, Tournament}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:player_count, length(Accounts.list_players()))
     |> assign(:fixture_count, length(Tournament.list_fixtures()))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.admin_nav active={:home} />
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

  @doc "Shared section nav bar for all admin LiveViews."
  attr :active, :atom, required: true

  def admin_nav(assigns) do
    ~H"""
    <nav class="tabs tabs-boxed mb-4">
      <.link navigate={~p"/admin"} class={["tab", @active == :home && "tab-active"]}>Home</.link>
      <.link
        navigate={~p"/admin/predictions"}
        class={["tab", @active == :predictions && "tab-active"]}
      >Predictions</.link>
      <.link navigate={~p"/admin/fixtures"} class={["tab", @active == :fixtures && "tab-active"]}>Fixtures</.link>
      <.link navigate={~p"/admin/players"} class={["tab", @active == :players && "tab-active"]}>Players</.link>
    </nav>
    """
  end
end
