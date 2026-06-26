defmodule Predictex.Bracket.Thirds do
  @moduledoc """
  Pure best-8-of-12 third-placed ranking for the projected R32 (`predictex-7qu`).

  In the 2026 format the eight best third-placed teams (of twelve groups) reach the Round
  of 32. This ranks each group's 3rd-placed row across all groups (points → GD → GF → team
  name) and marks the top eight as qualifying. It does NOT assign thirds to specific R32
  slots — that needs FIFA's 495-row table (see the spike); the page shows this ranked panel
  beside the bracket instead, and exact slot teams arrive via the openfootball ingest.
  """

  @qualify_count 8

  @doc "Rank the 3rd-placed teams across groups; mark the top 8 qualifying."
  def ranked(group_tables) do
    entries =
      group_tables
      |> Enum.map(fn {_group, rows} -> Enum.at(rows, 2) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn r -> {-r.points, -r.gd, -r.gf, r.team} end)
      |> Enum.with_index(1)
      |> Enum.map(fn {row, pos} ->
        %{position: pos, qualifying?: pos <= @qualify_count, row: row}
      end)

    %{entries: entries, cutoff_provisional?: cutoff_tie?(entries)}
  end

  defp cutoff_tie?(entries) do
    case {Enum.at(entries, @qualify_count - 1), Enum.at(entries, @qualify_count)} do
      {%{row: a}, %{row: b}} -> {a.points, a.gd, a.gf} == {b.points, b.gd, b.gf}
      _ -> false
    end
  end
end
