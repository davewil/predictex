defmodule Predictex.BuzzTest do
  use Predictex.DataCase, async: true
  alias Predictex.{Buzz, Tournament, Predictions}

  import Predictex.AccountsFixtures

  setup do
    # One round containing both the live fixture and a completed fixture.
    # Bob predicts the completed fixture: outcome correct (3-1 vs actual 1-0 → home win)
    # but goals wrong → 10 pts base. Ana predicts the live fixture (1-0) which is not
    # yet completed → 0 pts base. At base: Bob 10 pts (correct outcome on the completed
    # fixture), Ana 0 pts (her prediction is on the live, not-yet-completed fixture).
    # In home_next (1-0 projection), Ana earns her exact prediction (30 pts) and
    # overtakes Bob → "you climb" line is produced by narratives/4.
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "x",
        team1: "Portugal",
        team2: "Congo DR",
        round_id: r.id,
        kickoff_at: ~U[2026-06-17 17:00:00Z],
        status: :live,
        live_home_goals: 0,
        live_away_goals: 0
      })

    # Completed fixture in the same round — Bob predicts wrong outcome (0-1 vs actual 1-0).
    {:ok, completed_fx} =
      Tournament.create_fixture(%{
        external_ref: "y",
        team1: "Spain",
        team2: "Brazil",
        round_id: r.id,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })

    ana = player_fixture(%{display_name: "Ana", email: "a@b.c"})
    bob = player_fixture(%{display_name: "Bob"})

    # Ana predicts the live fixture (admin path bypasses kickoff lockout)
    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: ana.id,
        fixture_id: fx.id,
        home_goals: 1,
        away_goals: 0
      })

    # Bob predicts 3-1 on actual 1-0: outcome correct (+10), goals wrong → 10 pts base.
    # Round not complete (live fixture present) → no round bonus. Bob at 10, Ana at 0
    # at base. In home_next projection Ana earns exact (30) > Bob (10) → rank flip.
    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: bob.id,
        fixture_id: completed_fx.id,
        home_goals: 3,
        away_goals: 1
      })

    %{fx: fx, ana: ana, bob: bob}
  end

  test "scenarios/3 returns the three what-if leaderboards", %{fx: fx} do
    keys = Buzz.scenarios(fx.id, 0, 0) |> Enum.map(& &1.key)
    assert keys == [:end_now, :home_next, :away_next]
  end

  test "narratives mention the viewer with 'you' framing", %{fx: fx, ana: ana} do
    # Base: Bob 10 pts (completed fixture, correct outcome), Ana 0 pts (live fixture,
    # not yet completed). In home_next (1-0), Ana's exact prediction scores 30 pts → she
    # climbs above Bob. narratives/4 should emit at least one "you" line for Ana.
    lines = Buzz.narratives(fx.id, 0, 0, ana.id)
    assert Enum.any?(lines, &String.contains?(&1, "you"))
  end

  test "scenarios_with_deltas/3 rows carry rank, prev_rank and delta", %{fx: fx, ana: ana} do
    # Base: Bob #1 (10 pts), Ana #2 (0 pts). In :home_next (1-0) Ana earns 30 pts → #1,
    # Bob drops to #2. Ana's delta should be prev_rank(2) - rank(1) = +1 (climbed).
    result = Buzz.scenarios_with_deltas(fx.id, 0, 0)

    home_next = Enum.find(result, &(&1.key == :home_next))
    assert home_next != nil

    ana_row = Enum.find(home_next.rows, &(&1.player_id == ana.id))
    assert ana_row != nil
    assert ana_row.rank == 1
    assert ana_row.prev_rank == 2
    assert ana_row.delta == 1
  end

  test "headlines/4 includes a movement line and renders 'you' for the viewer", %{
    fx: fx,
    ana: ana,
    bob: bob
  } do
    # In :home_next (1-0), Ana climbs from #2 to #1, overtaking Bob.
    # As the viewer, Ana should see a "you overtake" line.
    lines = Buzz.headlines(fx.id, 0, 0, ana.id)

    assert length(lines) > 0
    assert Enum.any?(lines, &String.contains?(&1, "you"))

    assert Enum.any?(
             lines,
             &(String.contains?(&1, "overtake") or String.contains?(&1, "moves up to #"))
           )

    # Bob's name (the overtaken player) should appear in Ana's line
    assert Enum.any?(lines, &String.contains?(&1, bob.display_name))
  end
end
