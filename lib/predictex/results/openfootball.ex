defmodule Predictex.Results.Openfootball do
  @moduledoc """
  Pure parser for the `openfootball/worldcup.json` feed → fixture maps the scoring
  engine can consume.

  This is the **anti-corruption boundary**: it absorbs the feed's quirks (minutes as
  strings *or* integers, `"90+9"` stoppage notation, own goals listed under the
  beneficiary side) and emits clean, derived fields. `Predictex.Scoring` then trusts
  the shape. See `docs/rules.md` §9 for the data contract.

  Every function is pure — input map in, plain data out.
  """

  # A round is knockout iff its name contains one of these tokens; group games are
  # all "Matchday N", which contain none of them.
  @knockout ~r/round of|final|quarter|semi|third place|play-?off/i

  @doc "Parse a decoded openfootball document (`%{\"matches\" => [...]}`) into fixture maps."
  @spec parse(map()) :: [map()]
  def parse(%{"matches" => matches}) when is_list(matches), do: Enum.map(matches, &parse_match/1)
  def parse(_), do: []

  @doc "Parse a single openfootball match map into a fixture map."
  @spec parse_match(map()) :: map()
  def parse_match(m) when is_map(m) do
    round = Map.get(m, "round", "")
    {home_goals, away_goals, status} = ft_score(Map.get(m, "score"))
    first = first_scorer(Map.get(m, "goals1", []), Map.get(m, "goals2", []))
    team1 = Map.get(m, "team1")
    team2 = Map.get(m, "team2")

    %{
      external_ref: ref(Map.get(m, "date"), team1, team2),
      round: round,
      stage: stage_for(round),
      team1: team1,
      team2: team2,
      group: Map.get(m, "group"),
      date: Map.get(m, "date"),
      time: Map.get(m, "time"),
      kickoff_at: kickoff_at(Map.get(m, "date"), Map.get(m, "time")),
      status: status,
      home_goals: home_goals,
      away_goals: away_goals,
      first_scorer_side: first.side,
      first_scorer_player: first.player,
      first_goal_owngoal: first.owngoal,
      goals: goal_events(m)
    }
  end

  @doc "Classify a round name as `:group` or `:knockout`."
  @spec stage_for(String.t()) :: :group | :knockout
  def stage_for(round) when is_binary(round) do
    if Regex.match?(@knockout, round), do: :knockout, else: :group
  end

  def stage_for(_), do: :group

  @doc """
  Derive the first goal from a match's `goals1` (home) and `goals2` (away) arrays.

  Returns `%{side, player, owngoal}`. The earliest goal by elapsed minute wins;
  goals are listed under the team they count *for*, so the side is taken directly
  from which array holds the goal — even for own goals (player from the other team).
  """
  @spec first_scorer(list(), list()) :: %{
          side: :home | :away | nil,
          player: String.t() | nil,
          owngoal: boolean()
        }
  def first_scorer(goals1, goals2) do
    events =
      Enum.map(goals1 || [], &event(&1, :home)) ++ Enum.map(goals2 || [], &event(&1, :away))

    case Enum.sort_by(events, & &1.order) do
      [] -> %{side: nil, player: nil, owngoal: false}
      [first | _] -> %{side: first.side, player: first.player, owngoal: first.owngoal}
    end
  end

  @doc """
  All goals of a match as `[%{side, type, player, minute}]`, ordered by elapsed minute.
  Side is the array the goal sits in (own goals included — the beneficiary side). Type is
  `:penalty` / `:own_goal` / `:regular`. Minute is a display string ("16", "90+2").
  """
  @spec goal_events(map()) :: [map()]
  def goal_events(m) when is_map(m) do
    events =
      Enum.map(Map.get(m, "goals1", []) || [], &goal_event(&1, :home)) ++
        Enum.map(Map.get(m, "goals2", []) || [], &goal_event(&1, :away))

    events
    |> Enum.sort_by(& &1.__order)
    |> Enum.map(&Map.delete(&1, :__order))
  end

  def goal_events(_), do: []

  # --- internals ---

  defp goal_event(goal, side) when is_map(goal) do
    %{
      side: side,
      type: goal_type(goal),
      player: Map.get(goal, "name"),
      minute: minute_string(Map.get(goal, "minute"), Map.get(goal, "offset")),
      __order: order(Map.get(goal, "minute"), Map.get(goal, "offset"))
    }
  end

  defp goal_type(%{"owngoal" => true}), do: :own_goal
  defp goal_type(%{"penalty" => true}), do: :penalty
  defp goal_type(_), do: :regular

  defp minute_string(minute, offset) do
    {base, off} = order(minute, offset)
    if off > 0, do: "#{base}+#{off}", else: "#{base}"
  end

  defp event(goal, side) when is_map(goal) do
    %{
      side: side,
      player: Map.get(goal, "name"),
      owngoal: Map.get(goal, "owngoal", false) == true,
      order: order(Map.get(goal, "minute"), Map.get(goal, "offset"))
    }
  end

  # Full-time (regulation) score only — extra time (`et`) and penalties (`p`) are ignored.
  defp ft_score(%{"ft" => [h, a]}) do
    case {to_int(h), to_int(a)} do
      {hi, ai} when is_integer(hi) and is_integer(ai) -> {hi, ai, :completed}
      _ -> {nil, nil, :scheduled}
    end
  end

  defp ft_score(_), do: {nil, nil, :scheduled}

  # Goal ordering as `{base_minute, offset}` so stoppage time sorts correctly:
  # 45+2 → {45, 2} comes before minute 46 → {46, 0}. `minute` may be an integer
  # (2022) or a string, possibly "90+9" stoppage notation (2026); `offset` is the
  # 2022-style separate stoppage field. Both contribute to the offset component.
  defp order(minute, offset) do
    {base, inline_offset} = split_minute(minute)
    {base, inline_offset + zero(offset)}
  end

  defp split_minute(nil), do: {0, 0}
  defp split_minute(v) when is_integer(v), do: {v, 0}

  defp split_minute(v) when is_binary(v) do
    case Integer.parse(v) do
      {base, "+" <> rest} -> {base, zero(rest)}
      {base, _} -> {base, 0}
      :error -> {0, 0}
    end
  end

  defp split_minute(_), do: {0, 0}

  defp zero(nil), do: 0
  defp zero(v) when is_integer(v), do: v

  defp zero(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp zero(_), do: 0

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  @doc """
  Parse an openfootball `date` ("2026-06-11") and `time` ("13:00 UTC-6") into a UTC
  `DateTime` for lockout. Returns `nil` when either is missing or unparseable.
  """
  @spec kickoff_at(String.t() | nil, String.t() | nil) :: DateTime.t() | nil
  def kickoff_at(date, time) when is_binary(date) and is_binary(time) do
    with {:ok, d} <- Date.from_iso8601(date),
         {h, m, offset_hours} <- parse_time(time),
         {:ok, t} <- Time.new(h, m, 0),
         {:ok, naive} <- NaiveDateTime.new(d, t) do
      naive
      |> NaiveDateTime.add(-offset_hours * 3600, :second)
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.truncate(:second)
    else
      _ -> nil
    end
  end

  def kickoff_at(_, _), do: nil

  # "13:00 UTC-6" → {13, 0, -6}; "20:00" → {20, 0, 0}. The offset is the venue's
  # hours from UTC, so UTC = local - offset.
  defp parse_time(time) do
    case Regex.run(~r/^\s*(\d{1,2}):(\d{2})(?:\s+UTC\s*([+-]\d{1,2}))?/, time) do
      [_, h, m] -> {String.to_integer(h), String.to_integer(m), 0}
      [_, h, m, offset] -> {String.to_integer(h), String.to_integer(m), String.to_integer(offset)}
      _ -> :error
    end
  end

  defp ref(date, t1, t2), do: "#{date} #{t1} v #{t2}"
end
