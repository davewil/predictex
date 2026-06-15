defmodule PredictexWeb.AdminPlayersLive do
  @moduledoc "Admin player management: list players and promote to admin."
  use PredictexWeb, :live_view

  alias Predictex.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Players") |> load_players()}
  end

  defp load_players(socket), do: assign(socket, :players, Accounts.list_players())

  @impl true
  def handle_event("promote", %{"id" => id}, socket) do
    case Accounts.set_player_admin(String.to_integer(id), true) do
      {:ok, _} -> {:noreply, socket |> load_players() |> put_flash(:info, "Promoted to admin.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not promote player.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminComponents.admin_nav active={:players} />
      <table class="table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Email</th>
            <th>Admin?</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- @players}>
            <td>{p.display_name}</td>
            <td>{p.email}</td>
            <td>{if p.is_admin, do: "✓"}</td>
            <td>
              <button :if={!p.is_admin} phx-click="promote" phx-value-id={p.id} class="btn btn-sm">
                Make admin
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
