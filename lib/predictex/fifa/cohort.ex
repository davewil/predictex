defmodule Predictex.Fifa.Cohort do
  @moduledoc """
  Pure mapping of FIFA Match Predictor cohort percentages (`matchStats.json`) onto our
  fixtures, for the risky bonus. No DB, no network — the worker (`Workers.CohortSync`)
  does the I/O and calls `plan/3`.

  Match identity is the `{utc_date, unordered team-set}` of a fixture vs a FIFA match
  (`rounds.json` `tournaments[]`). Home/away is then oriented by the first-listed-is-home
  convention (our `team1` == FIFA `homeSquadName`); a source that orders a pair oppositely
  is handled by a logged swap so the win-shares still land on the correct team.

  FIFA `matchId` (`tournaments[].id`) keys `matchStats`. See
  `docs/superpowers/research/2026-06-16-xox-fifa-import-spike.md`.
  """
  require Logger

  # FIFA -> normalized openfootball name divergences (shared artifact with predictex-c9s).
  @aliases %{
    "ir iran" => "iran"
  }

  @doc """
  Pure. Returns `[%{fixture_id, cohort_home_pct, cohort_draw_pct, cohort_away_pct}]` for
  every FIFA match that resolves to a fixture and has a `matchStats` entry. Unmatched
  matches are omitted.
  """
  def plan(rounds, match_stats, fixtures)
      when is_list(rounds) and is_map(match_stats) and is_list(fixtures) do
    index = Map.new(fixtures, fn f -> {key(f.kickoff_at, f.team1, f.team2), f} end)

    rounds
    |> Enum.flat_map(fn r -> r["tournaments"] || [] end)
    |> Enum.flat_map(fn m ->
      stats = match_stats[to_string(m["id"])]
      fixture = Map.get(index, key(m["date"], m["homeSquadName"], m["awaySquadName"]))

      if is_map(stats) and fixture, do: [orient(m, stats, fixture)], else: []
    end)
  end

  defp orient(m, stats, f) do
    {home, away} =
      if norm(m["homeSquadName"]) == norm(f.team1) do
        {stats["homeWin"], stats["awayWin"]}
      else
        Logger.warning(
          "cohort orientation swap for fixture #{f.id} (#{f.team1} v #{f.team2}); " <>
            "FIFA match_id=#{m["id"]} home=#{m["homeSquadName"]}"
        )

        {stats["awayWin"], stats["homeWin"]}
      end

    %{
      fixture_id: f.id,
      cohort_home_pct: home,
      cohort_draw_pct: stats["draw"],
      cohort_away_pct: away
    }
  end

  defp key(datetime, a, b), do: {utc_date(datetime), MapSet.new([norm(a), norm(b)])}

  defp norm(nil), do: ""

  defp norm(name) when is_binary(name) do
    n = name |> String.downcase() |> String.trim() |> String.replace(~r/\s+/, " ")
    Map.get(@aliases, n, n)
  end

  # FIFA `date` is offset-bearing ISO8601 ("...+01:00"); from_iso8601 returns a UTC
  # DateTime. Fixture kickoff_at is already UTC. Both reduce to a UTC Date for the key.
  defp utc_date(%DateTime{} = dt), do: DateTime.to_date(dt)

  defp utc_date(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> DateTime.to_date(dt)
      _ -> nil
    end
  end

  defp utc_date(_), do: nil
end
