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
end
