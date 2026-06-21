defmodule Predictex.Buzz do
  @moduledoc """
  Live "what-if" buzz: project a live fixture under a few next-goal scenarios and turn the
  rank changes into shareable narratives. Pure over `Standings`; persists nothing.
  """
  alias Predictex.Standings

  @doc "The three scenario leaderboards for the current live score."
  def scenarios(fixture_id, home, away) do
    [
      %{
        key: :end_now,
        label: "if it ends #{home}-#{away}",
        leaderboard: Standings.project(fixture_id, home, away)
      },
      %{
        key: :home_next,
        label: "if home scores next",
        leaderboard: Standings.project(fixture_id, home + 1, away)
      },
      %{
        key: :away_next,
        label: "if away scores next",
        leaderboard: Standings.project(fixture_id, home, away + 1)
      }
    ]
  end

  @doc """
  Like `scenarios/3` but each row is enriched with rank movement vs the current standings.

  Returns `[%{key, label, rows: [%{player_id, name, total, rank, prev_rank, delta}]}]`.

  - `rank`      — 1-based position in that scenario's projected leaderboard.
  - `prev_rank` — player's 1-based rank in the current `Standings.leaderboard/0` (nil if absent).
  - `delta`     — `prev_rank - rank` when both present (positive = climbed), else nil.

  `Standings.leaderboard/0` is called exactly once.
  """
  def scenarios_with_deltas(fixture_id, home, away) do
    current = rank_index(Standings.leaderboard())

    for %{key: key, label: label, leaderboard: lb} <- scenarios(fixture_id, home, away) do
      %{key: key, label: label, rows: enrich_rows(lb, current)}
    end
  end

  @doc """
  "If your pick lands" projection (kcx): project the board assuming `fixture_id` finished
  `home`-`away` (the viewer's own scoreline pick), enriched with rank movement vs the current
  standings.

  Returns `%{rows: [%{player_id, name, total, rank, prev_rank, delta}], viewer: row | nil}`,
  where `viewer` is the row for `viewer_id` (pulled out for the pre-kickoff headline, where the
  per-player board is withheld for anti-copy). `Standings.leaderboard/0` is called exactly once.
  """
  def pick_projection(fixture_id, home, away, viewer_id) do
    current = rank_index(Standings.leaderboard())
    rows = enrich_rows(Standings.project(fixture_id, home, away), current)
    %{rows: rows, viewer: Enum.find(rows, &(&1.player_id == viewer_id))}
  end

  # Enrich a projected leaderboard with rank / prev_rank / delta vs the current `rank_index`.
  defp enrich_rows(leaderboard, current) do
    leaderboard
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, rank} ->
      prev_rank = get_in(current, [entry.player_id, :rank])

      delta =
        if not is_nil(prev_rank) and not is_nil(rank),
          do: prev_rank - rank,
          else: nil

      Map.merge(entry, %{rank: rank, prev_rank: prev_rank, delta: delta})
    end)
  end

  @doc """
  Punchy group movement lines for the viewer, covering all three scenarios.

  Returns `[String.t()]` — up to ~5 lines, biggest climbs first, deduped.
  Viewer (`viewer_id`) is referred to as "you". Only climbers (delta > 0) get lines.
  Returns `[]` when nothing moves in any scenario.
  """
  def headlines(fixture_id, home, away, viewer_id) do
    ranked_by_id = rank_index(Standings.leaderboard())

    scenarios_with_deltas(fixture_id, home, away)
    |> Enum.flat_map(fn %{label: label, rows: rows} ->
      rows_by_rank = Map.new(rows, &{&1.rank, &1})

      rows
      |> Enum.filter(&((&1.delta || 0) > 0))
      |> Enum.map(fn row ->
        {row.delta, headline_line(label, row, rows_by_rank, ranked_by_id, viewer_id)}
      end)
    end)
    |> Enum.uniq_by(fn {_delta, line} -> line end)
    |> Enum.sort_by(fn {delta, _line} -> -delta end)
    |> Enum.take(5)
    |> Enum.map(fn {_delta, line} -> line end)
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

  # Produces a single headline line for a climber row.
  # If the climber is the viewer, names the player they overtook ("you overtake <name> to #N").
  # Otherwise emits "<name> moves up to #N".
  defp headline_line(label, row, rows_by_rank, _ranked_by_id, viewer_id) do
    if row.player_id == viewer_id do
      # Find the player now directly below the viewer in the projected board
      overtaken = rows_by_rank[row.rank + 1]
      overtaken_name = if overtaken, do: overtaken.name, else: nil

      if overtaken_name do
        "#{label}, you overtake #{overtaken_name} to ##{row.rank}"
      else
        "#{label}, you move up to ##{row.rank}"
      end
    else
      "#{label}, #{row.name} moves up to ##{row.rank}"
    end
  end
end
