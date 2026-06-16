defmodule Predictex.Fifa.Import do
  @moduledoc """
  Pure core for member FIFA prediction import (group-stage scoreline + booster).

  `plan/3` partitions a decoded payload into `matched` (resolved to a Fixture, oriented to our
  home/away) and `unmatched` (with a reason). Lookup is keyed by the composite `{round, matchId}`
  against `rounds.json` — never a flat `matchId` map — because FIFA `tournaments[].id` may repeat
  per round; a flat map could resolve to the wrong real fixture and silently corrupt a result.

  No DB, no network. The edge (`ImportLive`) supplies `rounds` (via `Fifa.Reference`) and
  `fixtures` (via `Tournament`).
  """
  require Logger

  alias Predictex.Fifa.Crosswalk

  @group_rounds 1..3

  @doc "Decode a base64url-encoded JSON array of payload rows. `{:ok, rows} | {:error, :bad_payload}`."
  def decode_payload(b64) when is_binary(b64) do
    with {:ok, json} <- url_decode(b64),
         {:ok, rows} when is_list(rows) <- Jason.decode(json) do
      {:ok, rows}
    else
      _ -> {:error, :bad_payload}
    end
  end

  defp url_decode(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  @doc """
  Build `plan/3`-ready rows from a decoded FIFA prediction envelope (or a bare predictions list),
  injecting the known `round` (FIFA's response does not carry it — it is implied by which
  `/prediction/show/{round}` produced the data). Tolerates `%{"success" => %{"predictions" => [...]}}`
  and a top-level `[...]`. Entries without a `matchId` are skipped. `{:ok, rows} | {:error, :bad_envelope}`.
  """
  def rows_from_envelope(decoded, round) when is_integer(round) do
    case predictions(decoded) do
      nil ->
        {:error, :bad_envelope}

      list ->
        rows =
          for %{"matchId" => match_id} = p <- list do
            %{
              "round" => round,
              "matchId" => match_id,
              "homeScore" => p["homeScore"],
              "awayScore" => p["awayScore"],
              "booster" => p["booster"] == true
            }
          end

        {:ok, rows}
    end
  end

  defp predictions(%{"success" => %{"predictions" => p}}) when is_list(p), do: p
  defp predictions(p) when is_list(p), do: p
  defp predictions(_), do: nil

  @doc """
  Partition payload rows into `%{matched: [...], unmatched: [...]}`.

  A matched entry: `%{fixture_id, team1, team2, home_goals, away_goals, booster, round_id}`
  (`team1`/`team2` are for preview display only). An unmatched entry:
  `%{round, matchId, booster, reason}` with reason in
  `:out_of_scope | :unknown_match_id | :no_fixture | :invalid`.
  """
  def plan(payload_rows, rounds, fixtures)
      when is_list(payload_rows) and is_list(rounds) and is_list(fixtures) do
    index = Crosswalk.index_fixtures(fixtures)
    matches = build_match_index(rounds)

    {matched, unmatched} =
      Enum.reduce(payload_rows, {[], []}, fn row, {m, u} ->
        case resolve(row, matches, index) do
          {:ok, entry} -> {[entry | m], u}
          {:error, reason} -> {m, [unmatched_entry(row, reason) | u]}
        end
      end)

    %{matched: Enum.reverse(matched), unmatched: Enum.reverse(unmatched)}
  end

  defp build_match_index(rounds) do
    for r <- rounds, m <- r["tournaments"] || [], into: %{} do
      {{r["id"], m["id"]}, m}
    end
  end

  defp resolve(row, matches, index) do
    round = row["round"]
    match_id = row["matchId"]

    if round not in @group_rounds do
      {:error, :out_of_scope}
    else
      case Map.get(matches, {round, match_id}) do
        nil ->
          {:error, :unknown_match_id}

        match ->
          key = Crosswalk.match_key(match["date"], match["homeSquadName"], match["awaySquadName"])

          case Map.get(index, key) do
            nil -> {:error, :no_fixture}
            fixture -> build_matched(row, match, fixture)
          end
      end
    end
  end

  defp build_matched(row, match, fixture) do
    hs = row["homeScore"]
    as = row["awayScore"]

    if is_integer(hs) and is_integer(as) do
      {home_goals, away_goals} =
        if Crosswalk.home_first?(match["homeSquadName"], fixture.team1) do
          {hs, as}
        else
          Logger.info(
            "import orientation swap for fixture #{fixture.id} (#{fixture.team1} v #{fixture.team2})"
          )

          {as, hs}
        end

      {:ok,
       %{
         fixture_id: fixture.id,
         team1: fixture.team1,
         team2: fixture.team2,
         home_goals: home_goals,
         away_goals: away_goals,
         booster: row["booster"] == true,
         round_id: fixture.round_id
       }}
    else
      {:error, :invalid}
    end
  end

  defp unmatched_entry(row, reason),
    do: %{
      round: row["round"],
      matchId: row["matchId"],
      booster: row["booster"] == true,
      reason: reason
    }

  @doc "Group matched entries by `round_id`, stripped to the `save_round_row/3` write contract."
  def to_write_rows(matched) when is_list(matched) do
    matched
    |> Enum.group_by(& &1.round_id, fn m ->
      %{
        fixture_id: m.fixture_id,
        home_goals: m.home_goals,
        away_goals: m.away_goals,
        booster: m.booster
      }
    end)
  end
end
