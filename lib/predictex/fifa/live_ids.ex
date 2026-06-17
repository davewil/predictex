defmodule Predictex.Fifa.LiveIds do
  @moduledoc """
  Backfill `fixtures.fifa_match_id` from `rounds.json` (the FIFA `fifaId`), matched to
  fixtures by the existing date+team crosswalk. LiveScoreSync needs the FIFA match id to
  address the per-match detail endpoint.
  """
  alias Predictex.Fifa.Crosswalk
  alias Predictex.Tournament

  @doc "Pure join: [%{fixture_id, fifa_match_id}] for fixtures matched in rounds.json."
  def plan(rounds, fixtures) do
    by_key =
      for r <- rounds, t <- r["tournaments"] || [], into: %{} do
        {Crosswalk.match_key(t["date"], t["homeSquadName"], t["awaySquadName"]),
         to_string(t["fifaId"])}
      end

    for f <- fixtures,
        id = by_key[Crosswalk.match_key(f.kickoff_at, f.team1, f.team2)],
        not is_nil(id) do
      %{fixture_id: f.id, fifa_match_id: id}
    end
  end

  @doc "Fetch rounds.json (injectable) and write fifa_match_id. Returns {ok, total}."
  def assign(rounds) do
    by_id = Map.new(Tournament.list_fixtures(), &{&1.id, &1})

    plan(rounds, Map.values(by_id))
    |> Enum.reduce({0, 0}, fn %{fixture_id: fid, fifa_match_id: mid}, {ok, total} ->
      case Tournament.update_fixture(Map.fetch!(by_id, fid), %{fifa_match_id: mid}) do
        {:ok, _} -> {ok + 1, total + 1}
        {:error, _} -> {ok, total + 1}
      end
    end)
  end
end
