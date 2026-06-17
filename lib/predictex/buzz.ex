defmodule Predictex.Buzz do
  @moduledoc """
  Live "what-if" buzz: project a live fixture under a few next-goal scenarios and turn the
  rank changes into shareable narratives. Pure over `Standings`; persists nothing.
  """
  alias Predictex.Standings

  @doc "The three scenario leaderboards for the current live score."
  def scenarios(fixture_id, home, away) do
    [
      %{key: :end_now, label: "if it ends #{home}-#{away}", leaderboard: Standings.project(fixture_id, home, away)},
      %{key: :home_next, label: "if home scores next", leaderboard: Standings.project(fixture_id, home + 1, away)},
      %{key: :away_next, label: "if away scores next", leaderboard: Standings.project(fixture_id, home, away + 1)}
    ]
  end

  @doc """
  Rank-change narratives vs the current standings, framed for `viewer_id`.

  Returns `[]` for a viewer who has no current rank (e.g. a player who has no
  completed fixtures yet and therefore does not appear in the standings), since
  narratives are computed by diffing the projected leaderboard against the current
  standings — if the viewer has no rank to diff from, no narrative line can be
  produced.
  """
  def narratives(fixture_id, home, away, viewer_id) do
    current = rank_index(Standings.leaderboard())

    for %{label: label, leaderboard: lb} <- scenarios(fixture_id, home, away),
        line = viewer_line(label, current, rank_index(lb), viewer_id),
        not is_nil(line) do
      line
    end
  end

  defp rank_index(leaderboard) do
    leaderboard
    |> Enum.with_index(1)
    |> Map.new(fn {entry, rank} -> {entry.player_id, %{rank: rank, name: entry.name}} end)
  end

  defp viewer_line(label, current, projected, viewer_id) do
    with %{rank: from} <- current[viewer_id],
         %{rank: to} <- projected[viewer_id],
         true <- from != to do
      verb = if to < from, do: "climb to", else: "drop to"
      "#{label}, you #{verb} ##{to} (from ##{from})"
    else
      _ -> nil
    end
  end
end
