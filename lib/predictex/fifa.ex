defmodule Predictex.Fifa do
  @moduledoc """
  Pure mapping from the openfootball feed's vocabulary to the FIFA Match Predictor
  game's domain — specifically the **8 game Rounds** (`docs/rules.md` §4).

  Why this exists: openfootball labels group games `"Matchday N"` (a calendar
  counter across all 12 groups), whereas the predictor game has **Round 1/2/3** =
  each team's 1st/2nd/3rd group match. Knockout round names already line up with the
  game's rounds. Mapping the two vocabularies is the boundary the round bonus needs,
  and it is a pure function: fixtures in, fixtures (annotated with `:game_round`) out.

  `:game_round` is `%{ordinal: 1..8, name: String.t(), stage: :group | :knockout}`.

  Group-round assignment assumes the full group schedule is present (4-team groups,
  6 matches) and that group rounds are played in chronological order — both hold for
  the openfootball World Cup feed, which lists every fixture (future ones without a
  score).
  """

  @group_round_names %{1 => "Round 1", 2 => "Round 2", 3 => "Round 3"}

  # Checked in order; "Quarter-final"/"Semi-final" contain "final", so they must be
  # matched before the bare "final" rule. Third-place playoff scores under the Final.
  @knockout_rounds [
    {~r/round of 32/i, 4, "Round of 32"},
    {~r/round of 16/i, 5, "Round of 16"},
    {~r/quarter/i, 6, "Quarter-Finals"},
    {~r/semi/i, 7, "Semi-Finals"},
    {~r/third place/i, 8, "Final (inc. 3rd Place playoff)"},
    {~r/final/i, 8, "Final (inc. 3rd Place playoff)"}
  ]

  @doc "Annotate every fixture with its `:game_round`."
  @spec assign_rounds([map()]) :: [map()]
  def assign_rounds(fixtures) do
    {group_fx, ko_fx} = Enum.split_with(fixtures, &(&1.stage == :group))

    assigned_group =
      group_fx
      |> Enum.group_by(&Map.get(&1, :group))
      |> Enum.flat_map(fn {_group, fxs} -> assign_group_rounds(fxs) end)

    assigned_ko = Enum.map(ko_fx, &Map.put(&1, :game_round, knockout_round(&1.round)))

    assigned_group ++ assigned_ko
  end

  @doc "Map a knockout round name to its game round (`%{ordinal, name, stage}`)."
  @spec knockout_round(String.t()) :: map()
  def knockout_round(name) when is_binary(name) do
    Enum.find_value(@knockout_rounds, fn {re, ordinal, label} ->
      if Regex.match?(re, name), do: %{ordinal: ordinal, name: label, stage: :knockout}
    end) || %{ordinal: nil, name: name, stage: :knockout}
  end

  # --- internals ---

  defp assign_group_rounds(fixtures) do
    sorted = Enum.sort_by(fixtures, &{Map.get(&1, :date) || "", Map.get(&1, :time) || ""})
    per = max(div(length(sorted), 3), 1)

    sorted
    |> Enum.with_index()
    |> Enum.map(fn {fixture, i} ->
      ordinal = min(div(i, per) + 1, 3)
      Map.put(fixture, :game_round, group_round(ordinal))
    end)
  end

  defp group_round(ordinal) do
    %{ordinal: ordinal, name: Map.fetch!(@group_round_names, ordinal), stage: :group}
  end
end
