defmodule Predictex.MatchRecap do
  @moduledoc """
  Read model for the settled-match recap on `/fixtures/:id` (predictex-p4o).

  Pure functions over an already-loaded fixture + its predictions (+ an optional
  FIFA detail body). `FixtureLive` does the DB reads at the edge and calls these.
  """
  alias Predictex.Capture
  alias Predictex.Scoring

  @doc """
  Goal breakdown for the recap: the FIFA-capture goals when they reconcile with the final
  score (guards against a short/incomplete capture), otherwise the persisted openfootball
  goals. Both are normalised to `[%{side, type, player, minute}]`.
  """
  @spec goals(map(), map() | nil) :: [map()]
  def goals(fixture, fifa_body) do
    case fifa_goals_if_reconciled(fixture, fifa_body) do
      nil -> openfootball_goals(fixture)
      fifa -> fifa
    end
  end

  @doc "Which source `goals/2` selected — `:fifa` or `:openfootball`."
  @spec goal_source(map(), map() | nil) :: :fifa | :openfootball
  def goal_source(fixture, fifa_body) do
    if fifa_goals_if_reconciled(fixture, fifa_body), do: :fifa, else: :openfootball
  end

  defp fifa_goals_if_reconciled(_fixture, nil), do: nil

  defp fifa_goals_if_reconciled(fixture, body) do
    goals = Capture.goal_events(body)
    if reconciles?(goals, fixture), do: goals, else: nil
  end

  # Embedded %Goal{} structs → the plain unified shape the LiveView consumes.
  defp openfootball_goals(fixture) do
    Enum.map(
      fixture.goals,
      &%{side: &1.side, type: &1.type, player: &1.player, minute: &1.minute}
    )
  end

  # Per-side goal count (side is the scoring side incl. own-goal beneficiary) == final score.
  # Count check only — not a content match.
  defp reconciles?(goals, fixture) do
    Enum.count(goals, &(&1.side == :home)) == (fixture.home_goals || 0) and
      Enum.count(goals, &(&1.side == :away)) == (fixture.away_goals || 0)
  end

  @doc """
  Points each prediction earned on this fixture: `%{player_id => fixture_total}`.

  `fixture.round` must be preloaded (the stage drives knockout-only scoring lines).
  Uses `Scoring.score/3`, whose `:fixture_total` already folds in the ⚡ booster. This
  is the per-fixture contribution only — it deliberately excludes the round bonus, so it
  will not sum to the leaderboard total.
  """
  @spec points(map(), [map()]) :: %{integer() => integer()}
  def points(fixture, predictions) do
    stage = fixture.round.stage

    Map.new(predictions, fn pred ->
      {pred.player_id, Scoring.score(pred, fixture, stage).fixture_total}
    end)
  end
end
