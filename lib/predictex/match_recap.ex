defmodule Predictex.MatchRecap do
  @moduledoc """
  Read model for the settled-match recap on `/fixtures/:id` (predictex-p4o).

  Pure functions over an already-loaded fixture + its predictions (+ an optional
  FIFA detail body). `FixtureLive` does the DB reads at the edge and calls these.
  """
  alias Predictex.Scoring

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
