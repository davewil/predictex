defmodule Predictex.Fifa.LiveIds do
  @moduledoc """
  Backfill `fixtures.fifa_match_id` from `rounds.json` (the FIFA `fifaId`). `LiveScoreSync`
  needs the FIFA match id to address the per-match detail endpoint.

  Two matchers, in precedence order:

    * **name** — the date+team crosswalk (`Crosswalk.match_key/3`). Authoritative; the only
      matcher for the group stage (several matches per day, so the team-set is part of the key).
    * **slot** — date+time to the minute (`Crosswalk.slot_key/1`), used ONLY for a **knockout**
      fixture the name-join misses. Each knockout match has a distinct kickoff slot, so this is a
      1:1 join that is robust to openfootball lagging the bracket-team resolution — the case that
      would otherwise leave a knockout fixture unmatched (hence uncaptured) until both feeds agree
      on its teams. Verified equal to the minute across all 72 group matches. The slot index is a
      map keyed on `slot_key`, so it assumes one knockout match per minute-slot (true of the
      bracket); a duplicate slot would silently keep the last.

  Already-assigned fixtures are skipped, so re-runs don't churn and a later slot match can never
  clobber a fixture an earlier name match already resolved.
  """
  import Ecto.Query

  alias Predictex.Fifa.Crosswalk
  alias Predictex.Repo
  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture

  # FIFA `rounds.json` knockout `stage` tags.
  @ko_stages ~w(r32 r16 qf sf f)

  @doc """
  Pure join: `[%{fixture_id, fifa_match_id, via}]` for fixtures still missing a `fifa_match_id`,
  where `via` is `:name` or `:slot`. `fixtures` must have `:round` preloaded (for the
  knockout-only slot fallback).
  """
  def plan(rounds, fixtures) do
    name_idx =
      for r <- rounds, t <- r["tournaments"] || [], into: %{} do
        {Crosswalk.match_key(t["date"], t["homeSquadName"], t["awaySquadName"]),
         to_string(t["fifaId"])}
      end

    slot_idx =
      for r <- rounds, r["stage"] in @ko_stages, t <- r["tournaments"] || [], into: %{} do
        {Crosswalk.slot_key(t["date"]), to_string(t["fifaId"])}
      end

    for f <- fixtures,
        is_nil(f.fifa_match_id),
        {id, via} = resolve(f, name_idx, slot_idx),
        not is_nil(id) do
      %{fixture_id: f.id, fifa_match_id: id, via: via}
    end
  end

  # Name first (authoritative); a knockout fixture the name-join misses falls back to its unique
  # date+time slot. Group fixtures never slot-match (not 1:1 per slot).
  defp resolve(f, name_idx, slot_idx) do
    case name_idx[Crosswalk.match_key(f.kickoff_at, f.team1, f.team2)] do
      nil ->
        if knockout?(f), do: {slot_idx[Crosswalk.slot_key(f.kickoff_at)], :slot}, else: {nil, nil}

      id ->
        {id, :name}
    end
  end

  defp knockout?(%{round: %{stage: :knockout}}), do: true
  defp knockout?(_), do: false

  @doc """
  Writes `fifa_match_id` for each fixture matched in `rounds` and returns
  `%{assigned, by_name, by_slot, errors}`. Fetches its own fixtures (with `:round`); the caller
  fetches and passes `rounds`.
  """
  def assign(rounds) do
    fixtures = Repo.all(from(f in Fixture, preload: :round))
    by_id = Map.new(fixtures, &{&1.id, &1})

    plan(rounds, Map.values(by_id))
    |> Enum.reduce(%{assigned: 0, by_name: 0, by_slot: 0, errors: 0}, &write(&1, by_id, &2))
  end

  defp write(%{fixture_id: fid, fifa_match_id: mid, via: via}, by_id, acc) do
    # Safe: fid always comes from by_id's own keyset (produced by plan/2), so fetch! cannot miss.
    case Tournament.update_fixture(Map.fetch!(by_id, fid), %{fifa_match_id: mid}) do
      {:ok, _} -> acc |> Map.update!(:assigned, &(&1 + 1)) |> Map.update!(via_key(via), &(&1 + 1))
      {:error, _} -> Map.update!(acc, :errors, &(&1 + 1))
    end
  end

  defp via_key(:name), do: :by_name
  defp via_key(:slot), do: :by_slot
end
