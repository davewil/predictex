defmodule Predictex.Bracket do
  @moduledoc """
  Pure projection of the Round of 32 "as it stands" (`predictex-7qu`).

  `resolve_slot/2` is a TOTAL anti-corruption parser: every R32 placeholder the data carries
  (`"1C"` winner / `"2F"` runner-up / `"3A/B/C/D/F"` third-placed candidate set / an
  already-resolved real team name / anything unexpected) maps to a renderable value and never
  raises. Third-placed slots stay candidate sets — exact thirds arrive upstream via the
  openfootball/`Workers.KnockoutIds` ingest as `{:resolved, name}` (see the spike).
  """

  @winner_runner_up ~r/^([12])([A-Z])$/
  @third ~r{^3([A-Z])(?:/([A-Z]))+$}
  @later_round ~r/^[WL]\d+$/

  @doc "Resolve one R32 slot placeholder into a renderable value. Total."
  def resolve_slot(placeholder, group_tables) when is_binary(placeholder) do
    cond do
      caps = Regex.run(@winner_runner_up, placeholder) ->
        [_, pos, group] = caps
        resolve_position(group_tables, group, String.to_integer(pos))

      Regex.match?(@third, placeholder) ->
        groups = placeholder |> String.slice(1..-1//1) |> String.split("/")
        {:candidate_set, groups}

      Regex.match?(@later_round, placeholder) ->
        {:tbd, placeholder}

      true ->
        {:resolved, placeholder}
    end
  end

  defp resolve_position(group_tables, group, position) do
    case group_tables |> Map.get(group, []) |> Enum.at(position - 1) do
      %{team: team} -> {:exact, team}
      nil -> {:tbd, position_label(position, group)}
    end
  end

  defp position_label(1, group), do: "Winner #{group}"
  defp position_label(2, group), do: "Runners-up #{group}"
end
