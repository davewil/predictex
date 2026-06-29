defmodule Predictex.Bracket do
  @moduledoc """
  Pure projection of the Round of 32 "as it stands" (`predictex-7qu`).

  `resolve_slot/2` is a TOTAL anti-corruption parser: every R32 placeholder the data carries
  (`"1C"` winner / `"2F"` runner-up / `"3A/B/C/D/F"` third-placed candidate set / an
  already-resolved real team name / anything unexpected) maps to a renderable value and never
  raises. Third-placed slots stay candidate sets — exact thirds arrive upstream via the
  openfootball/`Workers.KnockoutIds` ingest as `{:resolved, name}` (see the spike).
  """

  alias Predictex.Bracket.Thirds
  alias Predictex.{Scoring.GroupTables, Scoring.Knockout, Tournament}

  @winner_runner_up ~r/^([12])([A-Z])$/
  # Non-capturing: only used with Regex.match?/2 (the candidate-set parse uses String.split,
  # not captures). Mirrors Knockout's @third grammar. (predictex-57t)
  @third ~r{^3[A-Z](?:/[A-Z])+$}

  @doc "Resolve one R32 slot placeholder into a renderable value. Total."
  def resolve_slot(placeholder, group_tables) when is_binary(placeholder) do
    cond do
      Knockout.resolved_team?(placeholder) ->
        {:resolved, placeholder}

      caps = Regex.run(@winner_runner_up, placeholder) ->
        [_, pos, group] = caps
        resolve_position(group_tables, group, String.to_integer(pos))

      Regex.match?(@third, placeholder) ->
        groups = placeholder |> String.slice(1..-1//1) |> String.split("/")
        {:candidate_set, groups}

      true ->
        {:tbd, placeholder}
    end
  end

  @doc "Pure projection: build the bracket view model from group + R32 fixtures."
  def build(group_fixtures, r32_fixtures) do
    tables = GroupTables.build(group_fixtures)

    matches =
      Enum.map(r32_fixtures, fn fx ->
        %{
          source_num: fx.source_num,
          kickoff_at: fx.kickoff_at,
          home: resolve_slot(fx.team1, tables),
          away: resolve_slot(fx.team2, tables)
        }
      end)

    %{matches: matches, group_tables: tables, thirds: Thirds.ranked(tables)}
  end

  @doc "Gather edge: load the fixtures and build the projection."
  def view do
    build(Tournament.group_stage_fixtures(), Tournament.r32_fixtures())
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
