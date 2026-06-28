defmodule Predictex.Fifa.Players do
  @moduledoc """
  Pure join of FIFA's static `players.json` and `squads.json` into per-team squad lists,
  keyed by `Crosswalk.norm(team)` so the openfootball fixture team name finds its squad
  (predictex-u4k). Each player is `%{name, position, goals, fifa_id}`; `fifa_id` is the
  canonical FIFA player id stored alongside the picked name for the exact-scoring follow-up.

  No I/O — `Fifa.Players.Cache` owns fetching and caching.
  """
  alias Predictex.Fifa.Crosswalk

  @positions %{1 => "GK", 2 => "DEF", 3 => "MID", 4 => "FWD"}

  @doc "Join players to squads, returning `%{norm(team) => [player]}` sorted goals-desc then name."
  @spec parse([map()], [map()]) :: %{String.t() => [map()]}
  def parse(players, squads) when is_list(players) and is_list(squads) do
    names = Map.new(squads, fn s -> {s["id"], s["name"]} end)

    players
    |> Enum.group_by(& &1["squadId"])
    |> Enum.flat_map(fn {squad_id, ps} ->
      case Map.get(names, squad_id) do
        nil -> []
        team -> [{Crosswalk.norm(team), build_squad(ps)}]
      end
    end)
    |> Map.new()
  end

  @doc "The squad list for one team name (alias-normalised); unknown team → `[]`."
  @spec for_team(%{String.t() => [map()]}, String.t()) :: [map()]
  def for_team(map, team) when is_map(map), do: Map.get(map, Crosswalk.norm(team), [])

  defp build_squad(players) do
    players
    |> Enum.map(fn p ->
      %{
        name: p["shortName"],
        position: Map.get(@positions, p["position"], ""),
        goals: get_in(p, ["stats", "goals"]) || 0,
        fifa_id: p["fifaId"]
      }
    end)
    |> Enum.sort_by(&{-&1.goals, &1.name})
  end
end
