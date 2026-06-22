defmodule Predictex.Ranking do
  @moduledoc """
  The pure ranking core: the fold both `Predictex.Standings` (FK join) and
  `Predictex.Leaderboard` (team-name join) share. No Repo, no Ecto — given
  already-joined scored entries it owns everything the two boards must agree on:
  the fixtures total, the Round Bonus completeness rule, the total, and the sort.

  Each adapter keeps only its **join** (resolve a prediction to a fixture) and
  feeds this core:

    * `scored_players` — one map per player. **Requires** `:name` (the tie-break
      key) and `:scored` (the player's per-fixture scoring results). Every other
      key is **echoed** onto the result untouched, so an adapter can carry
      identity (`:player_id`) through. Each `scored` entry **requires** `:ordinal`
      (its game-round ordinal, or `nil`) and `:result` (a `Scoring.score/3` map);
      any extra keys it carries (`:fixture_id`, `:fixture`, …) survive into the
      breakdown verbatim.
    * `round_fixtures` — the fixture universe as `[%{ordinal, completed?}]`. The
      core derives each round's size and completion from it, so the completeness
      rule lives here in the seam rather than in each adapter.

  **Produces**, merged onto each player's echoed fields (with `:scored` folded
  into `:breakdown`): `:fixtures_total`, `:round_bonus_total`, `:total`,
  `:bonus_by_round`, `:breakdown`. The list is sorted by `:total` descending,
  ties broken by `:name`.
  """

  alias Predictex.Scoring

  @doc """
  Rank `scored_players` over the `round_fixtures` universe. See the module doc
  for the input and output contract.
  """
  @spec rank([map()], [map()]) :: [map()]
  def rank(scored_players, round_fixtures) do
    rounds_meta = round_meta(round_fixtures)

    scored_players
    |> Enum.map(&tally(&1, rounds_meta))
    |> Enum.sort_by(&{-&1.total, &1.name})
  end

  # --- internals ---

  defp tally(%{scored: scored} = player, rounds_meta) do
    fixtures_total = scored |> Enum.map(& &1.result.fixture_total) |> Enum.sum()
    bonus_by_round = bonus_by_round(scored, rounds_meta)
    round_bonus_total = bonus_by_round |> Map.values() |> Enum.sum()

    player
    |> Map.delete(:scored)
    |> Map.merge(%{
      fixtures_total: fixtures_total,
      round_bonus_total: round_bonus_total,
      total: fixtures_total + round_bonus_total,
      bonus_by_round: bonus_by_round,
      breakdown: scored
    })
  end

  # Round Bonus per round ordinal (one computation feeds both the per-round figure
  # and the total, so they cannot drift). A round earns its bonus only when it is
  # fully completed and the player predicted every one of its fixtures.
  defp bonus_by_round(scored, rounds_meta) do
    scored
    |> Enum.group_by(& &1.ordinal)
    |> Map.new(fn {ordinal, entries} ->
      meta = Map.get(rounds_meta, ordinal)
      results = Enum.map(entries, & &1.result)

      complete? =
        not is_nil(ordinal) and meta != nil and meta.complete? and
          length(entries) == meta.count

      {ordinal, Scoring.round_total(results, complete?).round_bonus}
    end)
  end

  # Per-round-ordinal fixture count and whether every fixture is completed.
  defp round_meta(round_fixtures) do
    round_fixtures
    |> Enum.group_by(& &1.ordinal)
    |> Map.new(fn {ordinal, fxs} ->
      {ordinal, %{count: length(fxs), complete?: Enum.all?(fxs, & &1.completed?)}}
    end)
  end
end
