defmodule Predictex.PredictionsTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Accounts, Predictions, Tournament}

  setup do
    {:ok, round} = Tournament.create_round(%{name: "Round 1", stage: :group, ordinal: 1})
    {:ok, player} = Accounts.create_player(%{display_name: "Dave"})
    %{round: round, player: player}
  end

  defp fixture!(round, attrs \\ %{}) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      team1: "A",
      team2: "B",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  test "create_prediction sets round_id from the fixture", %{round: round, player: player} do
    f = fixture!(round)

    {:ok, pred} =
      Predictions.create_prediction(%{
        player_id: player.id,
        fixture_id: f.id,
        home_goals: 1,
        away_goals: 0
      })

    assert pred.round_id == round.id
  end

  test "only one prediction per player per fixture", %{round: round, player: player} do
    f = fixture!(round)

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: player.id,
        fixture_id: f.id,
        home_goals: 1,
        away_goals: 0
      })

    assert {:error, cs} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 2,
               away_goals: 2
             })

    assert %{player_id: ["already predicted this fixture"]} = errors_on(cs)
  end

  test "only one booster per player per round", %{round: round, player: player} do
    f1 = fixture!(round)
    f2 = fixture!(round)

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: player.id,
        fixture_id: f1.id,
        home_goals: 1,
        away_goals: 0,
        booster: true
      })

    assert {:error, cs} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f2.id,
               home_goals: 0,
               away_goals: 0,
               booster: true
             })

    assert %{player_id: ["booster already used in this round"]} = errors_on(cs)
  end

  test "two non-boosted predictions in the same round are allowed", %{
    round: round,
    player: player
  } do
    f1 = fixture!(round)
    f2 = fixture!(round)

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: player.id,
        fixture_id: f1.id,
        home_goals: 1,
        away_goals: 0
      })

    assert {:ok, _} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f2.id,
               home_goals: 0,
               away_goals: 0
             })
  end

  test "predictions lock at kickoff", %{round: round, player: player} do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{kickoff_at: past})

    assert {:error, :locked} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 1,
               away_goals: 0
             })
  end

  test "predictions are open before kickoff", %{round: round, player: player} do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{kickoff_at: future})

    assert {:ok, _} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 1,
               away_goals: 0
             })
  end

  test "an unknown fixture is rejected", %{player: player} do
    assert {:error, :fixture_not_found} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: 999_999,
               home_goals: 1,
               away_goals: 0
             })
  end
end
