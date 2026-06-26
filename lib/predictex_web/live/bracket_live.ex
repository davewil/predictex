defmodule PredictexWeb.BracketLive do
  @moduledoc """
  Public "as it stands" projected Round of 32 (`predictex-7qu`): live group tables (A–L) and
  the R32 matchups they imply, computed from actual results. Winner/runner-up slots resolve
  to exact teams; third-placed slots show their candidate set + a ranked best-thirds panel,
  and become exact named teams automatically once the group stage ends (via the ingest).
  Re-pulls on the coarse `:fixtures_changed` PubSub signal.
  """
  use PredictexWeb, :live_view

  alias Predictex.{Bracket, Tournament}
  alias PredictexWeb.Flags

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tournament.subscribe_changes()

    {:ok,
     socket
     |> assign(:page_title, "Bracket")
     |> assign_view()}
  end

  @impl true
  def handle_info(:fixtures_changed, socket), do: {:noreply, assign_view(socket)}

  defp assign_view(socket) do
    view = Bracket.view()

    socket
    |> assign(:matches, view.matches)
    |> assign(:group_tables, view.group_tables)
    |> assign(:thirds, view.thirds)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-6xl">
      <div class="space-y-6">
        <h1 class="text-2xl font-bold">As it stands · Round of 32</h1>

        <div :if={@matches == []} class="rounded-box bg-base-200 p-6 text-center">
          <p class="font-medium">No knockout bracket yet</p>
          <p class="text-sm opacity-70">The projected R32 appears once fixtures are seeded.</p>
        </div>

        <section :if={@matches != []} class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <div
            :for={m <- @matches}
            class="flex items-center justify-between rounded-box bg-base-200 p-3"
          >
            <span id={"r32-#{m.source_num}-home"} class="font-medium">{slot_label(m.home)}</span>
            <span class="px-2 text-sm opacity-60">v</span>
            <span id={"r32-#{m.source_num}-away"} class="font-medium">{slot_label(m.away)}</span>
          </div>
        </section>

        <section :if={@thirds.entries != []} class="rounded-box border border-base-300 p-4">
          <h2 class="mb-2 font-semibold">Best thirds so far — top 8 of 12 qualify</h2>
          <ol class="space-y-1 text-sm">
            <li
              :for={e <- @thirds.entries}
              class={["flex justify-between", not e.qualifying? && "opacity-50"]}
            >
              <span>
                {e.position}. {Flags.flag(e.row.team)} {e.row.team}
                <span class="opacity-60">(Group {e.row.group})</span>
              </span>
              <span class="font-mono">
                {e.row.points} pts · {format_gd(e.row.gd)}{if e.position == 8 and
                                                                @thirds.cutoff_provisional?,
                                                              do: " ⚠ level with 9th"}
              </span>
            </li>
          </ol>
        </section>

        <section
          :if={@group_tables != %{}}
          class="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3"
        >
          <div
            :for={{group, rows} <- Enum.sort_by(@group_tables, &elem(&1, 0))}
            class="rounded-box border border-base-300 p-3"
          >
            <h3 class="mb-2 font-semibold">Group {group}</h3>
            <table class="w-full text-sm">
              <tbody>
                <tr :for={r <- rows} class={[r.rank <= 2 && "font-semibold"]}>
                  <td class="py-0.5">{Flags.flag(r.team)} {r.team}{if r.rank == 3, do: " ▲"}</td>
                  <td class="py-0.5 text-right font-mono opacity-70">{r.played}</td>
                  <td class="py-0.5 text-right font-mono">{format_gd(r.gd)}</td>
                  <td class="py-0.5 text-right font-mono font-semibold">
                    {r.points}{if r.provisional_tie?, do: "*"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp slot_label({:exact, team}), do: "#{Flags.flag(team)} #{team}"
  defp slot_label({:resolved, team}), do: "#{Flags.flag(team)} #{team}"
  defp slot_label({:candidate_set, groups}), do: "3rd · #{Enum.join(groups, "/")}"
  defp slot_label({:tbd, label}), do: label

  defp format_gd(gd) when gd > 0, do: "+#{gd}"
  defp format_gd(gd), do: "#{gd}"
end
