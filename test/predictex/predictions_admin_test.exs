defmodule Predictex.PredictionsAdminTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Predictions, Tournament}
  import Predictex.AccountsFixtures

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

  setup do
    {:ok, round} = Tournament.create_round(%{name: "Round 1", stage: :group, ordinal: 1})
    player = player_fixture(%{display_name: "Dave"})
    %{round: round, player: player}
  end

  test "admin_upsert_prediction inserts a new prediction with round_id from the fixture",
       %{round: round, player: player} do
    f = fixture!(round)

    assert {:ok, pred} =
             Predictions.admin_upsert_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 2,
               away_goals: 1
             })

    assert pred.round_id == round.id
    assert pred.home_goals == 2
    assert pred.away_goals == 1
  end
end
