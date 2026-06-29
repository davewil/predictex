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

  defp slot_label({:exact, team}), do: "#{Flags.flag(team)} #{team}"
  defp slot_label({:resolved, team}), do: "#{Flags.flag(team)} #{team}"
  defp slot_label({:candidate_set, groups}), do: "3rd · #{Enum.join(groups, "/")}"
  defp slot_label({:tbd, label}), do: label

  defp format_gd(gd) when gd > 0, do: "+#{gd}"
  defp format_gd(gd), do: "#{gd}"
end
