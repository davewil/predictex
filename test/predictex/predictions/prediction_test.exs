defmodule Predictex.Predictions.PredictionTest do
  use ExUnit.Case, async: true

  alias Predictex.Predictions.Prediction

  test "fixture_id is enforced — a prediction is always for a fixture" do
    assert_raise ArgumentError, fn ->
      # `@enforce_keys [:fixture_id]` — building one without it is a compile/runtime error.
      struct!(Prediction, home_goals: 1, away_goals: 0)
    end
  end

  test "defaults: booster false, goals and first-scorer fields nil" do
    prediction = %Prediction{fixture_id: 42}

    assert prediction.booster == false
    assert prediction.home_goals == nil
    assert prediction.away_goals == nil
    assert prediction.first_scorer_side == nil
    assert prediction.first_scorer_player == nil
    assert prediction.first_scorer_fifaid == nil
  end
end
