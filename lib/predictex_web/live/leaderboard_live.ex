defmodule PredictexWeb.LeaderboardLive do
  @moduledoc """
  The league leaderboard — ranked standings from `Predictex.Standings`, with a
  one-tap "Copy WhatsApp text" button for sharing in the group chat.
  """
  use PredictexWeb, :live_view

  alias Predictex.{Standings, Tournament}

  @impl true
  def mount(_params, _session, socket) do
    overall = Standings.leaderboard()
    knockout = Standings.knockout_leaderboard()

    {:ok,
     socket
     |> assign(:page_title, "Leaderboard")
     |> assign(:completed, Tournament.completed_fixture_count())
     |> assign(:board, :overall)
     |> assign(:overall, overall)
     |> assign(:knockout, knockout)
     |> assign(:standings, overall)
     |> assign(:whatsapp_text, whatsapp_text(overall))
     |> assign(:live_fixtures, Tournament.list_live_fixtures())}
  end

  @impl true
  def handle_event("select_board", %{"board" => board}, socket) do
    board = String.to_existing_atom(board)
    standings = if board == :knockout, do: socket.assigns.knockout, else: socket.assigns.overall

    {:noreply,
     socket
     |> assign(:board, board)
     |> assign(:standings, standings)
     |> assign(:whatsapp_text, whatsapp_text(standings))}
  end

  embed_templates "leaderboard_live_body.html"

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :champion, List.first(assigns.standings))
      |> assign(:chasing, chasing_pack(assigns.standings))

    leaderboard_live_body(assigns)
  end

  # True when the standings entry belongs to the logged-in player. `current_scope` is
  # nil for logged-out visitors (Scope.for_player(nil)), so the catch-all keeps this total.
  defp you?(%{player: %{id: id}}, id), do: true
  defp you?(_scope, _player_id), do: false

  # ranks 2..N, each paired with its real rank number
  defp chasing_pack([]), do: []

  defp chasing_pack([_champion | rest]),
    do: rest |> Enum.with_index(2) |> Enum.map(fn {s, rank} -> {s, rank} end)

  defp whatsapp_text([]), do: "🏆 Predictex — World Cup 2026\nNo scores yet."

  defp whatsapp_text(standings) do
    rows =
      standings
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, rank} -> "#{rank}. #{s.name} — #{s.total}" end)

    "🏆 Predictex — World Cup 2026\n" <> rows
  end
end
