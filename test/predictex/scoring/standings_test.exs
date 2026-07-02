defmodule Predictex.Scoring.StandingsTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Predictions, Scoring.Standings, Tournament}

  import Predictex.AccountsFixtures

  # Round 1 (group, ordinal 1) with two completed fixtures: A 1-0 B and C 0-2 D.
  setup do
    {:ok, round} = Tournament.create_round(%{name: "Round 1", stage: :group, ordinal: 1})

    {:ok, f1} =
      Tournament.create_fixture(%{
        external_ref: "f1",
        team1: "A",
        team2: "B",
        status: :completed,
        home_goals: 1,
        away_goals: 0,
        round_id: round.id
      })

    {:ok, f2} =
      Tournament.create_fixture(%{
        external_ref: "f2",
        team1: "C",
        team2: "D",
        status: :completed,
        home_goals: 0,
        away_goals: 2,
        round_id: round.id
      })

    %{round: round, f1: f1, f2: f2}
  end

  defp predict!(player, fixture, home, away, opts \\ []) do
    attrs =
      %{player_id: player.id, fixture_id: fixture.id, home_goals: home, away_goals: away}
      |> Map.merge(Map.new(opts))

    {:ok, _} = Predictions.create_prediction(attrs)
  end

  test "scores DB predictions and ranks players, awarding the round bonus", %{f1: f1, f2: f2} do
    dave = player_fixture(%{display_name: "Dave"})
    sam = player_fixture(%{display_name: "Sam"})

    # Dave nails both exact scores → 30 + 30, and predicted all of Round 1 correctly → +20.
    predict!(dave, f1, 1, 0)
    predict!(dave, f2, 0, 2)

    # Sam: f1 exact (30); f2 predicted as a draw (wrong outcome) → only the home-goals +5.
    predict!(sam, f1, 1, 0)
    predict!(sam, f2, 0, 0)

    assert [first, second] = Standings.leaderboard()

    assert first.name == "Dave"
    assert first.fixtures_total == 60
    assert first.round_bonus_total == 20
    assert first.total == 80

    assert second.name == "Sam"
    assert second.fixtures_total == 35
    assert second.round_bonus_total == 0
    assert second.total == 35
  end

  test "a player with no predictions scores zero and still ranks", %{f1: f1} do
    dave = player_fixture(%{display_name: "Dave"})
    _lurker = player_fixture(%{display_name: "Lurker"})
    predict!(dave, f1, 1, 0)

    standings = Standings.leaderboard()
    assert Enum.map(standings, & &1.name) == ["Dave", "Lurker"]
    assert List.last(standings).total == 0
  end

  test "booster doubles a fixture's points in the standings", %{f1: f1, f2: f2} do
    dave = player_fixture(%{display_name: "Dave"})
    predict!(dave, f1, 1, 0, booster: true)
    predict!(dave, f2, 0, 2)

    [dave_standing] = Standings.leaderboard()
    # f1 exact 30 doubled = 60, f2 exact 30 = 90 fixtures, + round bonus 20 = 110
    assert dave_standing.fixtures_total == 90
    assert dave_standing.total == 110
  end

  test "breakdown entries carry fixture_id and bonus_by_round sums to round_bonus_total", %{
    f1: f1,
    f2: f2
  } do
    dave = player_fixture(%{display_name: "Dave"})
    predict!(dave, f1, 1, 0)
    predict!(dave, f2, 0, 2)

    standings = Standings.leaderboard()
    first = hd(standings)

    # breakdown carries the exact fixture ids Dave predicted in setup
    actual_ids = first.breakdown |> Enum.map(& &1.fixture_id) |> MapSet.new()
    assert actual_ids == MapSet.new([f1.id, f2.id])

    # Dave swept the completed round 1 (ordinal 1) → a single +20 round bonus
    assert first.bonus_by_round == %{1 => 20}
  end

  describe "knockout_leaderboard/0 (re-based, knockout-only)" do
    test "ranks only knockout-stage points, ignoring group fixtures" do
      {:ok, group} = Tournament.create_round(%{name: "Group 2", stage: :group, ordinal: 2})
      {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 5})

      {:ok, gfx} =
        Tournament.create_fixture(%{
          external_ref: "g1",
          team1: "A",
          team2: "B",
          round_id: group.id,
          status: :completed,
          home_goals: 1,
          away_goals: 0
        })

      {:ok, kfx} =
        Tournament.create_fixture(%{
          external_ref: "k1",
          team1: "C",
          team2: "D",
          round_id: ko.id,
          status: :completed,
          home_goals: 2,
          away_goals: 1
        })

      alice = player_fixture(%{display_name: "Alice"})

      # Exact group pick (would be +30 on the overall board) and exact KO pick (+30 KO-only).
      {:ok, _} =
        Predictions.create_prediction(%{
          player_id: alice.id,
          fixture_id: gfx.id,
          home_goals: 1,
          away_goals: 0
        })

      {:ok, _} =
        Predictions.admin_upsert_prediction(%{
          player_id: alice.id,
          fixture_id: kfx.id,
          home_goals: 2,
          away_goals: 1
        })

      # Dave (module setup) has group-stage-only predictions, so Alice is the only knockout scorer.
      [row] = Standings.knockout_leaderboard()
      assert row.player_id == alice.id
      # Knockout board excludes the group fixture entirely: only the KO pick counts.
      assert row.fixtures_total == 30
      assert Enum.all?(row.breakdown, fn b -> b.fixture_id == kfx.id end)
    end

    test "a player with only group points sits at 0 on the knockout board" do
      {:ok, group} = Tournament.create_round(%{name: "Group 3", stage: :group, ordinal: 3})

      {:ok, gfx} =
        Tournament.create_fixture(%{
          external_ref: "g2",
          team1: "A",
          team2: "B",
          round_id: group.id,
          status: :completed,
          home_goals: 1,
          away_goals: 0
        })

      bob = player_fixture(%{display_name: "Bob"})

      {:ok, _} =
        Predictions.create_prediction(%{
          player_id: bob.id,
          fixture_id: gfx.id,
          home_goals: 1,
          away_goals: 0
        })

      # Dave (module setup) has group-stage-only predictions, so Bob is the only knockout scorer.
      [row] = Standings.knockout_leaderboard()
      assert row.player_id == bob.id
      assert row.total == 0
    end
  end

  describe "snapshot/0 + rank/1 + project/4 (single Gather edge → pure ranking)" do
    test "rank(snapshot()) matches leaderboard/0", %{f1: f1, f2: f2} do
      dave = player_fixture(%{display_name: "Dave"})
      predict!(dave, f1, 1, 0)
      predict!(dave, f2, 0, 2)

      assert Standings.rank(Standings.snapshot()) == Standings.leaderboard()
    end

    test "snapshot/0 carries players (with predictions) and fixtures (with round)", %{f1: f1} do
      dave = player_fixture(%{display_name: "Dave"})
      predict!(dave, f1, 1, 0)

      assert %Standings.Snapshot{players: players, fixtures: fixtures} = Standings.snapshot()
      assert Enum.any?(players, fn p -> p.id == dave.id and is_list(p.predictions) end)
      assert Enum.any?(fixtures, fn f -> f.id == f1.id and match?(%{stage: _}, f.round) end)
    end

    test "project/4 swaps one fixture to completed and re-ranks — pure, no DB" do
      # Hand-built snapshot, no Repo: a scheduled fixture and two players with different picks.
      round = %Predictex.Tournament.Round{id: 1, ordinal: 1, stage: :group}

      fixture = %Predictex.Tournament.Fixture{
        id: 100,
        status: :scheduled,
        home_goals: nil,
        away_goals: nil,
        round: round
      }

      exact = %Predictex.Accounts.Player{
        id: 1,
        display_name: "Exact",
        predictions: [
          %Predictex.Predictions.SavedPrediction{fixture_id: 100, home_goals: 2, away_goals: 1}
        ]
      }

      off = %Predictex.Accounts.Player{
        id: 2,
        display_name: "Off",
        predictions: [
          %Predictex.Predictions.SavedPrediction{fixture_id: 100, home_goals: 0, away_goals: 0}
        ]
      }

      snapshot = %Standings.Snapshot{players: [exact, off], fixtures: [fixture]}

      # Nothing completed yet → everyone sits at 0.
      assert Enum.all?(Standings.rank(snapshot), &(&1.total == 0))

      # Project the fixture to 2-1 → the exact predictor leads with a positive total.
      assert [leader | _] = Standings.project(snapshot, 100, 2, 1)
      assert leader.player_id == exact.id
      assert leader.total > 0
    end
  end
end
