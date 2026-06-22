defmodule Predictex.Standings.Snapshot do
  @moduledoc """
  The loaded inputs for ranking, captured once at a single instant: every player (with
  `:predictions`) and every fixture (with its `:round`).

  The opaque carrier that the pure `Predictex.Standings.rank/1` and
  `Predictex.Standings.project/4` — and, through them, every `Predictex.Buzz` projection —
  run over without touching the DB. One live event takes one snapshot instead of reloading
  per projection, and every projection in that event sees a single consistent instant.
  """
  @enforce_keys [:players, :fixtures]
  defstruct [:players, :fixtures]

  @type t :: %__MODULE__{players: [struct()], fixtures: [struct()]}
end
