defmodule Predictex.StandingsTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Predictions, Standings, Tournament}

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
end
