defmodule Predictex.Scoring.GroupTables do
  @moduledoc """
  Pure (DB-free) computation of the football group tables "as it stands" from actual
  results — the foundation of the projected R32 bracket (`predictex-7qu`).

  Only `:completed` fixtures with integer scores contribute to the table (a live or
  scheduled fixture is not yet a result). Own goals are already reflected in the score, so
  no special handling is needed. Tiebreakers are pragmatic — points → goal difference →
  goals for → team name (stable) — with `provisional_tie?` flagging any row level with a
  neighbour on points+GD+GF.
  """

  alias Predictex.Scoring.GroupTables.Row

  defmodule Row do
    @moduledoc "One team's standing within its group."
    @enforce_keys [:team, :group]
    defstruct team: nil,
              group: nil,
              played: 0,
              won: 0,
              drawn: 0,
              lost: 0,
              gf: 0,
              ga: 0,
              gd: 0,
              points: 0,
              rank: nil,
              provisional_tie?: false

    @type t :: %__MODULE__{}
  end

  @doc "Build `%{group_letter => [Row.t()]}` from a list of group-stage fixtures."
  def build(fixtures) do
    fixtures
    |> Enum.filter(& &1.group)
    |> Enum.group_by(& &1.group)
    |> Map.new(fn {group, fxs} -> {group, rank_group(group, fxs)} end)
  end

  defp rank_group(group, fxs) do
    fxs
    |> init_rows(group)
    |> tally(fxs)
    |> Map.values()
    |> Enum.sort_by(fn r -> {-r.points, -r.gd, -r.gf, r.team} end)
    |> assign_ranks()
  end

  defp init_rows(fxs, group) do
    fxs
    |> Enum.flat_map(&[&1.team1, &1.team2])
    |> Enum.uniq()
    |> Map.new(fn team -> {team, %Row{team: team, group: group}} end)
  end

  defp tally(rows, fxs), do: Enum.reduce(fxs, rows, &apply_fixture/2)

  defp apply_fixture(
         %{status: :completed, team1: h, team2: a, home_goals: hg, away_goals: ag},
         rows
       )
       when is_integer(hg) and is_integer(ag) do
    rows |> update_row(h, hg, ag) |> update_row(a, ag, hg)
  end

  defp apply_fixture(_fixture, rows), do: rows

  defp update_row(rows, team, gf, ga) do
    Map.update!(rows, team, fn %Row{} = r ->
      {w, d, l, pts} =
        cond do
          gf > ga -> {1, 0, 0, 3}
          gf == ga -> {0, 1, 0, 1}
          true -> {0, 0, 1, 0}
        end

      %Row{
        r
        | played: r.played + 1,
          won: r.won + w,
          drawn: r.drawn + d,
          lost: r.lost + l,
          gf: r.gf + gf,
          ga: r.ga + ga,
          gd: r.gd + (gf - ga),
          points: r.points + pts
      }
    end)
  end

  defp assign_ranks(sorted) do
    keys = Enum.map(sorted, &tie_key/1)
    n = length(sorted)

    sorted
    |> Enum.with_index()
    |> Enum.map(fn {%Row{} = r, i} ->
      tied? =
        (i > 0 and Enum.at(keys, i - 1) == Enum.at(keys, i)) or
          (i < n - 1 and Enum.at(keys, i + 1) == Enum.at(keys, i))

      %Row{r | rank: i + 1, provisional_tie?: tied?}
    end)
  end

  defp tie_key(r), do: {r.points, r.gd, r.gf}
end
