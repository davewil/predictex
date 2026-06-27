defmodule Predictex.Knockout do
  @moduledoc """
  Pure knockout-stage predicates shared across the projected bracket (`predictex-7qu`) and the
  per-fixture native entry gate (`predictex-80k`).

  `resolved_team?/1` is the single definition of "is this fixture slot a resolved real team or
  still a bracket placeholder". The placeholder grammar (group winner/runner-up `1C`/`2F`,
  third-placed candidate set `3A/B/C/D/F`, later-round `W89`/`L101`) is owned here so the bracket
  read-model and the prediction write path can never disagree about what counts as resolved.
  """

  @winner_runner_up ~r/^[12][A-Z]$/
  @third ~r{^3[A-Z](?:/[A-Z])+$}
  @later_round ~r/^[WL]\d+$/

  @doc "True iff `name` is a real team name (not a bracket placeholder). Total."
  def resolved_team?(name) when is_binary(name) do
    not (Regex.match?(@winner_runner_up, name) or Regex.match?(@third, name) or
           Regex.match?(@later_round, name))
  end

  def resolved_team?(_), do: false

  @doc """
  Human-friendly label for a fixture slot (predictex-94u): a real team name passes through; a
  placeholder is spelled out — `"1A"` → "Winner A", `"2B"` → "Runners-up B", `"3A/B/C/D/F"` →
  "3rd · A/B/C/D/F", `"W89"` → "Winner of 89", `"L101"` → "Loser of 101". Total.
  """
  def slot_label(name) when is_binary(name) do
    cond do
      resolved_team?(name) ->
        name

      caps = Regex.run(~r/^([12])([A-Z])$/, name) ->
        [_, pos, group] = caps
        "#{if pos == "1", do: "Winner", else: "Runners-up"} #{group}"

      Regex.match?(@third, name) ->
        "3rd · " <> String.slice(name, 1..-1//1)

      caps = Regex.run(~r/^([WL])(\d+)$/, name) ->
        [_, side, num] = caps
        "#{if side == "W", do: "Winner", else: "Loser"} of #{num}"

      true ->
        name
    end
  end

  def slot_label(_), do: ""
end
