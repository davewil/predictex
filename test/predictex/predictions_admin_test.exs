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

  test "admin_upsert_prediction overwrites an existing pick for the same fixture",
       %{round: round, player: player} do
    f = fixture!(round)

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: f.id,
        home_goals: 0,
        away_goals: 0
      })

    assert {:ok, pred} =
             Predictions.admin_upsert_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 3,
               away_goals: 2
             })

    assert pred.home_goals == 3
    assert pred.away_goals == 2
    # overwrite, not a second row
    assert Repo.aggregate(Predictex.Predictions.Prediction, :count) == 1
  end

  test "admin_upsert_prediction succeeds even after kickoff (no lockout)",
       %{round: round, player: player} do
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{kickoff_at: past})

    assert {:ok, _pred} =
             Predictions.admin_upsert_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 1,
               away_goals: 1
             })
  end

  test "admin_upsert_prediction moving a booster A->B clears the old booster",
       %{round: round, player: player} do
    a = fixture!(round)
    b = fixture!(round)

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: a.id,
        home_goals: 1,
        away_goals: 0,
        booster: true
      })

    assert {:ok, pred_b} =
             Predictions.admin_upsert_prediction(%{
               player_id: player.id,
               fixture_id: b.id,
               home_goals: 2,
               away_goals: 0,
               booster: true
             })

    assert pred_b.booster
    pred_a = Repo.get_by(Predictex.Predictions.Prediction, player_id: player.id, fixture_id: a.id)
    refute pred_a.booster
  end

  test "admin_upsert_prediction returns :fixture_not_found for an unknown fixture",
       %{player: player} do
    assert {:error, :fixture_not_found} =
             Predictions.admin_upsert_prediction(%{
               player_id: player.id,
               fixture_id: -1,
               home_goals: 1,
               away_goals: 0
             })
  end

  test "admin_save_round_predictions upserts complete rows, skips blank, errors half-filled",
       %{round: round, player: player} do
    full = fixture!(round)
    blank = fixture!(round)
    half = fixture!(round)

    rows = [
      %{fixture_id: full.id, home_goals: 2, away_goals: 1, booster: false},
      %{fixture_id: blank.id, home_goals: nil, away_goals: nil, booster: false},
      %{fixture_id: half.id, home_goals: 1, away_goals: nil, booster: false}
    ]

    {:ok, results} = Predictions.admin_save_round_predictions(player.id, round.id, rows)

    assert results[full.id] == :upserted
    assert results[blank.id] == :skipped
    assert match?({:error, _}, results[half.id])
    assert Repo.aggregate(Predictex.Predictions.Prediction, :count) == 1
  end

  test "admin_save_round_predictions sets exactly one booster across the round",
       %{round: round, player: player} do
    a = fixture!(round)
    b = fixture!(round)

    {:ok, _} =
      Predictions.admin_save_round_predictions(player.id, round.id, [
        %{fixture_id: a.id, home_goals: 1, away_goals: 0, booster: true},
        %{fixture_id: b.id, home_goals: 0, away_goals: 0, booster: false}
      ])

    # Move the booster to B in a second save.
    {:ok, _} =
      Predictions.admin_save_round_predictions(player.id, round.id, [
        %{fixture_id: a.id, home_goals: 1, away_goals: 0, booster: false},
        %{fixture_id: b.id, home_goals: 0, away_goals: 0, booster: true}
      ])

    boosted = Repo.all(from p in Predictex.Predictions.Prediction, where: p.booster == true)
    assert length(boosted) == 1
    assert hd(boosted).fixture_id == b.id
  end

  test "list_fixture_predictions returns every player's pick for a fixture, player preloaded",
       %{round: round, player: player} do
    other = player_fixture(%{display_name: "Sam"})
    f = fixture!(round)

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: f.id,
        home_goals: 1,
        away_goals: 0
      })

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: other.id,
        fixture_id: f.id,
        home_goals: 2,
        away_goals: 2
      })

    preds = Predictions.list_fixture_predictions(f.id)

    assert length(preds) == 2
    assert Enum.all?(preds, fn p -> p.player.display_name in ["Dave", "Sam"] end)
  end

  test "admin_save_round_predictions rolls back a booster placed on a blank row, preserving a prior booster",
       %{round: round, player: player} do
    a = fixture!(round)
    blank = fixture!(round)

    # Player already has a valid booster on A.
    {:ok, _} =
      Predictions.admin_save_round_predictions(player.id, round.id, [
        %{fixture_id: a.id, home_goals: 1, away_goals: 0, booster: true}
      ])

    # Admin fumbles: moves the booster onto a blank row. This must NOT silently
    # destroy A's booster — the whole save rolls back.
    assert {:error, {:booster_on_blank, results}} =
             Predictions.admin_save_round_predictions(player.id, round.id, [
               %{fixture_id: a.id, home_goals: 1, away_goals: 0, booster: false},
               %{fixture_id: blank.id, home_goals: nil, away_goals: nil, booster: true}
             ])

    assert results[blank.id] == {:error, :booster_on_blank}

    # A's booster survived the rollback; nothing was written for the blank row.
    pred_a = Repo.get_by(Predictex.Predictions.Prediction, player_id: player.id, fixture_id: a.id)
    assert pred_a.booster
    assert Repo.aggregate(Predictex.Predictions.Prediction, :count) == 1
  end
end
