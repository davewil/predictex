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
end
