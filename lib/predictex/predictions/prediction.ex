defmodule Predictex.Predictions.Prediction do
  @moduledoc """
  A player's prediction as a value: their validated guess for one fixture, ready to
  persist. This is what the prediction-intake boundary emits — decoupled from the
  Ecto entity `Predictex.Predictions.SavedPrediction` (the persisted record).

  The shared shape every producer (member form, admin form, FIFA import) builds and
  `Predictions.validate_predictions/1` holds to the booster-needs-a-scoreline
  invariant. Field names match the `SavedPrediction` changeset and
  `Predictex.Scoring.Engine.score/3`. FIFA import leaves the first-scorer fields nil.

  `:fixture_id` is enforced (a prediction is always for a fixture); goals may be nil
  (a blank scoreline the persistence layer decides to skip); `:booster` defaults to
  false.
  """

  @enforce_keys [:fixture_id]
  defstruct [
    :fixture_id,
    :home_goals,
    :away_goals,
    :first_scorer_side,
    :first_scorer_player,
    :first_scorer_fifaid,
    booster: false
  ]

  @type t :: %__MODULE__{
          fixture_id: pos_integer(),
          home_goals: non_neg_integer() | nil,
          away_goals: non_neg_integer() | nil,
          first_scorer_side: :home | :away | nil,
          first_scorer_player: String.t() | nil,
          first_scorer_fifaid: pos_integer() | nil,
          booster: boolean()
        }
end
