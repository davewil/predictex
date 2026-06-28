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

  Fully-resolved fixtures (FIFA id + stage) are skipped, so re-runs don't churn and a later slot
  match can never clobber a fixture an earlier name match already resolved. A knockout fixture that
  has an id but no `fifa_stage_id` (assigned before the stage column existed) is backfilled with its
  FIFA stage id — parsed from the `matchcentreUrl` — so live capture addresses the right stage
  without changing the resolved id. The live `/detail` endpoint is keyed per stage, and each
  knockout round is a distinct stage, so the stage is as essential as the match id for KO capture.
  """
  import Ecto.Query

  alias Predictex.Fifa.Crosswalk
  alias Predictex.Repo
  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture

  # FIFA `rounds.json` knockout `stage` tags.
  @ko_stages ~w(r32 r16 qf sf f)

  @doc """
  Pure join: `[%{fixture_id, fifa_match_id, fifa_stage_id, via}]` for fixtures that still need FIFA
  addressing — either missing a `fifa_match_id` (`via` `:name`/`:slot`) or a knockout fixture whose
  `fifa_stage_id` hasn't been backfilled yet (`via` `:stage`, id left unchanged). `fixtures` must
  have `:round` preloaded (for the knockout-only slot fallback and the stage-backfill guard).
  """
  def plan(rounds, fixtures) do
    name_idx =
      for r <- rounds, t <- r["tournaments"] || [], into: %{} do
        {Crosswalk.match_key(t["date"], t["homeSquadName"], t["awaySquadName"]), entry(t)}
      end

    slot_idx =
      for r <- rounds, r["stage"] in @ko_stages, t <- r["tournaments"] || [], into: %{} do
        {Crosswalk.slot_key(t["date"]), entry(t)}
      end

    stage_idx =
      for r <- rounds, t <- r["tournaments"] || [], into: %{} do
        {to_string(t["fifaId"]), stage_from(t)}
      end

    Enum.flat_map(fixtures, fn f -> List.wrap(resolve_entry(f, name_idx, slot_idx, stage_idx)) end)
  end

  # A fixture needs work when it has no FIFA id yet, or it's a knockout fixture whose stage id
  # hasn't been backfilled (an id assigned before the stage column existed → live capture would
  # address the wrong, group, stage). A fully-resolved fixture (id + stage) is skipped.
  defp resolve_entry(f, name_idx, slot_idx, stage_idx) do
    cond do
      is_nil(f.fifa_match_id) ->
        case lookup(f, name_idx, slot_idx) do
          {{id, stage}, via} ->
            %{fixture_id: f.id, fifa_match_id: id, fifa_stage_id: stage, via: via}

          _ ->
            nil
        end

      knockout?(f) and is_nil(f.fifa_stage_id) ->
        case stage_idx[f.fifa_match_id] do
          nil ->
            nil

          stage ->
            %{fixture_id: f.id, fifa_match_id: f.fifa_match_id, fifa_stage_id: stage, via: :stage}
        end

      true ->
        nil
    end
  end

  # Name first (authoritative); a knockout fixture the name-join misses falls back to its unique
  # date+time slot. Group fixtures never slot-match (not 1:1 per slot). Returns `{{id, stage}, via}`
  # on a hit, or a non-matching shape (`{nil, _}`) that `resolve_entry/4` discards.
  defp lookup(f, name_idx, slot_idx) do
    case name_idx[Crosswalk.match_key(f.kickoff_at, f.team1, f.team2)] do
      nil ->
        if knockout?(f), do: {slot_idx[Crosswalk.slot_key(f.kickoff_at)], :slot}, else: {nil, nil}

      val ->
        {val, :name}
    end
  end

  # A rounds.json tournament → `{fifaId_string, stage_id}`.
  defp entry(t), do: {to_string(t["fifaId"]), stage_from(t)}

  # The FIFA live `/detail` stage segment, parsed from the match's `matchcentreUrl`
  # (`.../{competition}/{season}/{stage}/{matchId}?...`) — the second-from-last path segment.
  defp stage_from(t) do
    with url when is_binary(url) <- t["matchcentreUrl"],
         [_match_id, stage | _] <-
           url |> String.split("?") |> hd() |> String.split("/", trim: true) |> Enum.reverse() do
      stage
    else
      _ -> nil
    end
  end

  defp knockout?(%{round: %{stage: :knockout}}), do: true
  defp knockout?(_), do: false

  @doc """
  Writes `fifa_match_id` (+ `fifa_stage_id`) for each fixture matched in `rounds` and returns
  `%{assigned, by_name, by_slot, by_stage, errors}` (`by_stage` = knockout fixtures whose id was
  already set and only the stage was backfilled). Fetches its own fixtures (with `:round`); the
  caller fetches and passes `rounds`.
  """
  def assign(rounds) do
    fixtures = Repo.all(from(f in Fixture, preload: :round))
    by_id = Map.new(fixtures, &{&1.id, &1})

    plan(rounds, Map.values(by_id))
    |> Enum.reduce(
      %{assigned: 0, by_name: 0, by_slot: 0, by_stage: 0, errors: 0},
      &write(&1, by_id, &2)
    )
  end

  defp write(%{fixture_id: fid, fifa_match_id: mid, fifa_stage_id: stage, via: via}, by_id, acc) do
    # Safe: fid always comes from by_id's own keyset (produced by plan/2), so fetch! cannot miss.
    case Tournament.update_fixture(Map.fetch!(by_id, fid), %{
           fifa_match_id: mid,
           fifa_stage_id: stage
         }) do
      {:ok, _} -> acc |> Map.update!(:assigned, &(&1 + 1)) |> Map.update!(via_key(via), &(&1 + 1))
      {:error, _} -> Map.update!(acc, :errors, &(&1 + 1))
    end
  end

  defp via_key(:name), do: :by_name
  defp via_key(:slot), do: :by_slot
  defp via_key(:stage), do: :by_stage
end
