defmodule Predictex.Capture do
  @moduledoc """
  Permanent capture store for raw FIFA v3 API responses (predictex-rfm).

  `record_snapshot/1` persists one raw API response; `list_snapshots/1` reads a match's
  capture timeline back. `summary/1` prints (and returns) an analysis of a captured
  match — status/score transitions, the distinct `MatchStatus` values seen, the first
  populated `now` entry, and the goal timeline — so the post-match readout is one call:

      bin/predictex rpc "Predictex.Capture.summary(\\"400021502\\")"
  """
  import Ecto.Query, only: [from: 2]

  alias Predictex.Repo
  alias Predictex.Capture.Snapshot

  def record_snapshot(attrs) do
    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert()
  end

  def list_snapshots(match_id) do
    Repo.all(
      from c in Snapshot,
        where: c.match_id == ^match_id,
        order_by: [asc: c.captured_at]
    )
  end

  @doc "Read a match's snapshots, print a human summary, and return the analysis map."
  def summary(match_id) do
    result = match_id |> list_snapshots() |> analyze()
    IO.puts(format(result))
    result
  end

  @doc """
  Pure analysis of a snapshot list. Returns a map with the capture counts, the distinct
  `MatchStatus` values seen, the status/score `transitions` (one row each time status or
  score changed), the first populated `now` entry, and the goal timeline from the last
  detail snapshot (scorer ids resolved to names via the embedded `Players`).
  """
  def analyze(captures) do
    sorted = Enum.sort_by(captures, & &1.captured_at, DateTime)
    details = Enum.filter(sorted, &(&1.endpoint == "detail" and is_map(&1.body)))
    nows = Enum.filter(sorted, &(&1.endpoint == "now"))

    %{
      match_id: sorted |> List.first() |> then(&(&1 && &1.match_id)),
      total: length(sorted),
      by_endpoint: Enum.frequencies_by(sorted, & &1.endpoint),
      errors: Enum.count(sorted, &(&1.error != nil)),
      first_at: sorted |> List.first() |> then(&(&1 && &1.captured_at)),
      last_at: sorted |> List.last() |> then(&(&1 && &1.captured_at)),
      statuses_seen:
        details |> Enum.map(&status/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
      transitions: transitions(details),
      now_first_populated: first_populated_now(nows),
      goals: goals_from_last_detail(details)
    }
  end

  # --- pure helpers ---

  defp status(c), do: c.body["MatchStatus"]
  defp period(c), do: c.body["Period"]
  defp time(c), do: c.body["MatchTime"]

  defp score(c),
    do: {get_in(c.body, ["HomeTeam", "Score"]), get_in(c.body, ["AwayTeam", "Score"])}

  defp transitions(details) do
    details
    |> Enum.reduce({nil, []}, fn c, {prev, acc} ->
      key = {status(c), score(c)}

      if key == prev do
        {prev, acc}
      else
        {h, a} = score(c)

        row = %{
          at: c.captured_at,
          status: status(c),
          period: period(c),
          time: time(c),
          home: h,
          away: a
        }

        {key, [row | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp first_populated_now(nows) do
    nows
    |> Enum.find(fn c ->
      is_map(c.body) and is_list(c.body["Results"]) and c.body["Results"] != []
    end)
    |> case do
      nil ->
        nil

      c ->
        results = c.body["Results"]

        %{
          at: c.captured_at,
          count: length(results),
          entry_keys: results |> hd() |> Map.keys() |> Enum.sort()
        }
    end
  end

  defp goals_from_last_detail([]), do: []

  defp goals_from_last_detail(details) do
    body = List.last(details).body
    players = player_map(body)

    for {team, side} <- [{"HomeTeam", "home"}, {"AwayTeam", "away"}],
        goal <- get_in(body, [team, "Goals"]) || [] do
      %{
        minute: goal["Minute"],
        side: side,
        type: goal_type(goal["Type"]),
        scorer: Map.get(players, goal["IdPlayer"]) || goal["IdPlayer"],
        id_team: goal["IdTeam"]
      }
    end
    |> Enum.sort_by(&minute_key(&1.minute))
  end

  defp player_map(body) do
    for team <- ["HomeTeam", "AwayTeam"],
        p <- get_in(body, [team, "Players"]) || [],
        into: %{} do
      {p["IdPlayer"], loc_name(p["PlayerName"]) || loc_name(p["ShortName"])}
    end
  end

  defp loc_name([%{"Description" => d} | _]), do: d
  defp loc_name(_), do: nil

  # Decoded from baseline samples (see fifa-v3-live-api-contract memory).
  defp goal_type(1), do: "penalty"
  defp goal_type(2), do: "goal"
  defp goal_type(3), do: "own_goal"
  defp goal_type(other), do: "type_#{inspect(other)}"

  defp minute_key(s) when is_binary(s) do
    case Regex.run(~r/^\d+/, s) do
      [n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp minute_key(_), do: 0

  # --- formatting ---

  defp format(%{match_id: nil}), do: "no captures found"

  defp format(r) do
    [
      "== FIFA capture summary: match #{r.match_id} ==",
      "captures: #{r.total} (#{kv(r.by_endpoint)}) | errors: #{r.errors}",
      "window: #{r.first_at} .. #{r.last_at}",
      "MatchStatus values seen: #{inspect(r.statuses_seen)}",
      "",
      "-- status / score transitions --",
      transitions_block(r.transitions),
      "",
      "-- 'now' endpoint --",
      now_block(r.now_first_populated),
      "",
      "-- goals (final detail snapshot) --",
      goals_block(r.goals)
    ]
    |> Enum.join("\n")
  end

  defp kv(map), do: map |> Enum.map(fn {k, v} -> "#{k}: #{v}" end) |> Enum.join(", ")

  defp transitions_block([]), do: "  (none)"

  defp transitions_block(rows) do
    Enum.map_join(rows, "\n", fn t ->
      "  #{t.at}  status=#{inspect(t.status)} period=#{inspect(t.period)} time=#{inspect(t.time)}  score=#{score_str(t.home, t.away)}"
    end)
  end

  defp score_str(h, a), do: "#{h || "-"}-#{a || "-"}"

  defp now_block(nil), do: "  never populated (no live match seen in /now)"

  defp now_block(%{at: at, count: count, entry_keys: keys}) do
    "  first populated at #{at} with #{count} match(es)\n  live entry keys: #{inspect(keys)}"
  end

  defp goals_block([]), do: "  (none)"

  defp goals_block(goals) do
    Enum.map_join(goals, "\n", fn g ->
      "  #{g.minute}  #{g.side}  #{g.type}  #{g.scorer}  (IdTeam #{g.id_team})"
    end)
  end
end
