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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <PredictexWeb.AdminComponents.admin_nav active={:players} />

      <h2 class="mb-3 text-xs font-bold uppercase tracking-widest text-base-content/55">
        Players &amp; roles
      </h2>
      <div class="overflow-hidden rounded-box border border-base-300">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>Email</th>
              <th>Role</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={p <- @players}>
              <td class="font-semibold">{p.display_name}</td>
              <td class="text-base-content/70">{p.email}</td>
              <td>
                <span
                  :if={p.is_admin}
                  class="rounded-md border border-error/35 bg-error/15 px-2 py-0.5 text-[10px] font-extrabold uppercase tracking-wider text-error"
                >
                  Admin
                </span>
                <span :if={!p.is_admin} class="text-xs text-base-content/50">Member</span>
              </td>
              <td class="text-right">
                <button
                  :if={!p.is_admin}
                  phx-click="promote"
                  phx-value-id={p.id}
                  class="btn btn-sm btn-soft"
                >
                  Make admin
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
