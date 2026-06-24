defmodule Predictex.DashboardTest do
  use ExUnit.Case, async: true

  alias Predictex.Dashboard
  alias Predictex.Tournament.{Round, Fixture}
  alias Predictex.Predictions.Prediction

  defp dt(offset), do: DateTime.add(~U[2026-06-15 12:00:00Z], offset, :second)

  defp round_with(ordinal, stage, fixtures),
    do: %Round{
      id: ordinal,
      ordinal: ordinal,
      stage: stage,
      name: "R#{ordinal}",
      fixtures: fixtures
    }

  defp build_dash(rounds),
    do: Dashboard.build(rounds, %{}, %{entry: nil, rank: 1, of: 1}, ~U[2026-06-15 12:00:00Z])

  # A `Scoring.score/3`-shaped components map — production always sets every key,
  # so test doubles must too (CLAUDE.md: test fixtures stay honest to the contract).
  defp components(overrides) do
    Map.merge(
      %{
        correct_outcome: 0,
        correct_home_goals: 0,
        correct_away_goals: 0,
        correct_goal_difference: 0,
        correct_score_bonus: 0,
        risky_bonus: 0,
        first_team_to_score: 0,
        first_player_to_score: 0
      },
      overrides
    )
  end

  test "build assembles per-fixture view and takes points/total/rank from the standings entry" do
    now = ~U[2026-06-15 12:00:00Z]

    completed = %Fixture{
      id: 1,
      round_id: 1,
      team1: "Mexico",
      team2: "Poland",
      status: :completed,
      home_goals: 2,
      away_goals: 1,
      kickoff_at: dt(-3600)
    }

    locked = %Fixture{
      id: 2,
      round_id: 1,
      team1: "France",
      team2: "Denmark",
      status: :scheduled,
      kickoff_at: dt(-60)
    }

    open_unpredicted = %Fixture{
      id: 3,
      round_id: 1,
      team1: "Brazil",
      team2: "Serbia",
      status: :scheduled,
      kickoff_at: dt(3600)
    }

    rounds = [round_with(1, :group, [completed, locked, open_unpredicted])]

    preds = %{
      1 => %Prediction{fixture_id: 1, home_goals: 2, away_goals: 1, booster: true},
      2 => %Prediction{fixture_id: 2, home_goals: 1, away_goals: 1, booster: false}
    }

    entry = %{
      player_id: 7,
      name: "Dave",
      total: 70,
      fixtures_total: 50,
      round_bonus_total: 20,
      bonus_by_round: %{1 => 20},
      breakdown: [
        %{
          ordinal: 1,
          fixture_id: 1,
          result: %{
            fixture_total: 60,
            booster: true,
            components:
              components(%{
                correct_outcome: 10,
                correct_home_goals: 5,
                correct_away_goals: 5,
                correct_goal_difference: 5,
                correct_score_bonus: 5
              })
          }
        }
      ]
    }

    view = Dashboard.build(rounds, preds, %{entry: entry, rank: 9, of: 14}, now)

    assert view.rank == 9 and view.of == 14
    assert view.total == 70 and view.fixtures_total == 50 and view.round_bonus_total == 20

    [r1] = view.rounds
    assert r1.active? and r1.round_bonus == 20
    [fc, fl, fo] = r1.fixtures

    assert fc.points == 60 and fc.booster? and fc.exact?
    assert fl.locked? and fl.points == nil and fl.prediction
    assert fo.prediction == nil and fo.locked? == false
  end

  describe "per-fixture scoring breakdown" do
    defp entry_with(breakdown),
      do: %{
        player_id: 7,
        name: "Dave",
        total: 0,
        fixtures_total: 0,
        round_bonus_total: 0,
        bonus_by_round: %{},
        breakdown: breakdown
      }

    defp scored_round(fixture, prediction, result) do
      rounds = [round_with(1, :group, [fixture])]
      preds = %{fixture.id => prediction}
      entry = entry_with([%{ordinal: 1, fixture_id: fixture.id, result: result}])

      view =
        Dashboard.build(rounds, preds, %{entry: entry, rank: 1, of: 1}, ~U[2026-06-15 12:00:00Z])

      hd(hd(view.rounds).fixtures)
    end

    test "surfaces non-zero components as labelled, toned chips in canonical order" do
      fixture = %Fixture{
        id: 1,
        round_id: 1,
        team1: "Mexico",
        team2: "Poland",
        status: :completed,
        home_goals: 2,
        away_goals: 1,
        kickoff_at: dt(-3600)
      }

      pred = %Prediction{fixture_id: 1, home_goals: 1, away_goals: 0, booster: false}

      # correct away/home win outcome + goal difference, but wrong scoreline → no exact
      result = %{
        fixture_total: 15,
        booster: false,
        components: components(%{correct_outcome: 10, correct_goal_difference: 5})
      }

      fv = scored_round(fixture, pred, result)

      assert fv.breakdown == [
               %{label: "Outcome", pts: 10, tone: "success"},
               %{label: "GD", pts: 5, tone: "success"}
             ]

      assert fv.points == 15
      refute fv.booster?
      assert fv.risky_pct == nil
    end

    test "risky_pct reads the cohort share of the predicted winning side that triggered the bonus" do
      fixture = %Fixture{
        id: 1,
        round_id: 1,
        team1: "Morocco",
        team2: "Spain",
        status: :completed,
        home_goals: 1,
        away_goals: 0,
        cohort_home_pct: 12,
        cohort_away_pct: 81,
        kickoff_at: dt(-3600)
      }

      # predicted Morocco (home) to win — the underdog side
      pred = %Prediction{fixture_id: 1, home_goals: 2, away_goals: 1, booster: false}

      result = %{
        fixture_total: 25,
        booster: false,
        components:
          components(%{correct_outcome: 10, correct_goal_difference: 5, risky_bonus: 10})
      }

      fv = scored_round(fixture, pred, result)

      assert %{label: "Risky", pts: 10, tone: "accent"} in fv.breakdown
      assert fv.risky_pct == 12
    end

    test "boosted fixture keeps base components — the headline points are doubled (reconciles via booster?)" do
      fixture = %Fixture{
        id: 1,
        round_id: 1,
        status: :completed,
        home_goals: 2,
        away_goals: 1,
        kickoff_at: dt(-3600)
      }

      pred = %Prediction{fixture_id: 1, home_goals: 2, away_goals: 1, booster: true}

      result = %{
        fixture_total: 60,
        booster: true,
        components:
          components(%{
            correct_outcome: 10,
            correct_home_goals: 5,
            correct_away_goals: 5,
            correct_goal_difference: 5,
            correct_score_bonus: 5
          })
      }

      fv = scored_round(fixture, pred, result)

      # chips sum to the BASE (30); points is the doubled headline (60); booster? lets the UI show ×2
      assert Enum.sum(Enum.map(fv.breakdown, & &1.pts)) == 30
      assert fv.points == 60
      assert fv.booster?
    end

    test "breakdown is nil when the fixture has no scored result yet" do
      fixture = %Fixture{
        id: 1,
        round_id: 1,
        status: :scheduled,
        kickoff_at: dt(3600)
      }

      pred = %Prediction{fixture_id: 1, home_goals: 1, away_goals: 1, booster: false}
      rounds = [round_with(1, :group, [fixture])]

      view =
        Dashboard.build(
          rounds,
          %{1 => pred},
          %{entry: nil, rank: 1, of: 1},
          ~U[2026-06-15 12:00:00Z]
        )

      fv = hd(hd(view.rounds).fixtures)

      assert fv.breakdown == nil
      assert fv.risky_pct == nil
      assert fv.points == nil
    end
  end

  test "build with no standings entry yields zeroes, never crashes" do
    now = ~U[2026-06-15 12:00:00Z]

    f = %Fixture{
      id: 1,
      round_id: 1,
      team1: "A",
      team2: "B",
      status: :scheduled,
      kickoff_at: dt(3600)
    }

    rounds = [round_with(1, :group, [f])]

    view = Dashboard.build(rounds, %{}, %{entry: nil, rank: 1, of: 1}, now)
    assert view.total == 0
    assert [%{points: nil, prediction: nil}] = hd(view.rounds).fixtures
  end

  test "active round is the lowest-ordinal not fully complete" do
    now = ~U[2026-06-15 12:00:00Z]

    done = %Fixture{
      id: 1,
      round_id: 1,
      status: :completed,
      home_goals: 0,
      away_goals: 0,
      kickoff_at: dt(-99)
    }

    todo = %Fixture{id: 2, round_id: 2, status: :scheduled, kickoff_at: dt(99)}
    rounds = [round_with(1, :group, [done]), round_with(2, :group, [todo])]

    view = Dashboard.build(rounds, %{}, %{entry: nil, rank: 1, of: 1}, now)
    assert Enum.find(view.rounds, & &1.active?).round.ordinal == 2
  end

  test "active round is the last ordinal when all rounds complete" do
    now = ~U[2026-06-15 12:00:00Z]

    done1 = %Fixture{
      id: 1,
      round_id: 1,
      status: :completed,
      home_goals: 1,
      away_goals: 0,
      kickoff_at: dt(-200)
    }

    done2 = %Fixture{
      id: 2,
      round_id: 2,
      status: :completed,
      home_goals: 0,
      away_goals: 0,
      kickoff_at: dt(-100)
    }

    rounds = [round_with(1, :group, [done1]), round_with(2, :group, [done2])]

    view = Dashboard.build(rounds, %{}, %{entry: nil, rank: 1, of: 1}, now)
    assert Enum.find(view.rounds, & &1.active?).round.ordinal == 2
  end

  describe "next_tick_delay/2" do
    test "nil when there are no rounds" do
      dash = build_dash([])
      assert Dashboard.next_tick_delay(dash, dt(0)) == nil
    end

    test "nil when every fixture is completed" do
      done = %Fixture{
        id: 1,
        round_id: 1,
        status: :completed,
        home_goals: 1,
        away_goals: 0,
        kickoff_at: dt(-3600)
      }

      dash = build_dash([round_with(1, :group, [done])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == nil
    end

    test "nil when the only fixtures have no kickoff time" do
      tbc = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: nil}
      dash = build_dash([round_with(1, :group, [tbc])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == nil
    end

    test "gap to the preview window when more than 30 min before kickoff" do
      # kickoff in 1h; the preview opens 30 min before → 1_800_000 ms away
      fx = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: dt(3600)}
      dash = build_dash([round_with(1, :group, [fx])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == 1_800_000
    end

    test "gap to kickoff once inside the 30 min preview window" do
      # kickoff in 10m; preview already open → next event is the lock at kickoff
      fx = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: dt(600)}
      dash = build_dash([round_with(1, :group, [fx])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == 600_000
    end

    test "nil once kickoff has passed — live scores and the settle arrive via PubSub, not the clock (predictex-9p0)" do
      fx = %Fixture{id: 1, round_id: 1, status: :live, kickoff_at: dt(-60)}
      dash = build_dash([round_with(1, :group, [fx])])
      assert Dashboard.next_tick_delay(dash, dt(0)) == nil
    end

    test "takes the soonest threshold across all rounds" do
      near = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: dt(2400)}
      far = %Fixture{id: 2, round_id: 2, status: :scheduled, kickoff_at: dt(7200)}
      dash = build_dash([round_with(1, :group, [near]), round_with(2, :group, [far])])
      # near: preview opens in 2400 - 1800 = 600s → 600_000 ms (the minimum)
      assert Dashboard.next_tick_delay(dash, dt(0)) == 600_000
    end

    test "floors a sub-second threshold at 1000 ms" do
      ko = ~U[2026-06-15 12:00:00Z]
      now = ~U[2026-06-15 11:59:59.500Z]
      fx = %Fixture{id: 1, round_id: 1, status: :scheduled, kickoff_at: ko}
      dash = build_dash([round_with(1, :group, [fx])])
      # preview opened 30 min ago; the lock is 500 ms away → floored
      assert Dashboard.next_tick_delay(dash, now) == 1_000
    end
  end

  describe "next_match/2" do
    test "returns the soonest upcoming (future, non-completed) fixture across rounds" do
      now = ~U[2026-06-15 12:00:00Z]

      soon = %Fixture{
        id: 10,
        round_id: 1,
        team1: "England",
        team2: "Croatia",
        status: :scheduled,
        kickoff_at: dt(1800)
      }

      later = %Fixture{
        id: 11,
        round_id: 2,
        team1: "Spain",
        team2: "Iran",
        status: :scheduled,
        kickoff_at: dt(7200)
      }

      past = %Fixture{
        id: 12,
        round_id: 1,
        team1: "A",
        team2: "B",
        status: :scheduled,
        kickoff_at: dt(-60)
      }

      done = %Fixture{
        id: 13,
        round_id: 2,
        team1: "C",
        team2: "D",
        status: :completed,
        kickoff_at: dt(-3600)
      }

      rounds = [round_with(1, :group, [past, soon]), round_with(2, :group, [done, later])]
      dash = Dashboard.build(rounds, %{}, %{entry: nil, rank: 1, of: 1}, now)

      nm = Dashboard.next_match(dash, now)
      assert nm.fixture.id == 10
      assert nm.fixture.team1 == "England"
    end

    test "ignores fixtures whose kickoff has already passed (live/in-play)" do
      now = ~U[2026-06-15 12:00:00Z]

      live = %Fixture{
        id: 20,
        round_id: 1,
        team1: "A",
        team2: "B",
        status: :scheduled,
        is_live: true,
        kickoff_at: dt(-300)
      }

      upcoming = %Fixture{
        id: 21,
        round_id: 1,
        team1: "Up",
        team2: "Coming",
        status: :scheduled,
        kickoff_at: dt(600)
      }

      dash =
        Dashboard.build(
          [round_with(1, :group, [live, upcoming])],
          %{},
          %{entry: nil, rank: 1, of: 1},
          now
        )

      assert Dashboard.next_match(dash, now).fixture.id == 21
    end

    test "returns nil when there are no upcoming fixtures" do
      now = ~U[2026-06-15 12:00:00Z]

      done = %Fixture{
        id: 30,
        round_id: 1,
        team1: "A",
        team2: "B",
        status: :completed,
        kickoff_at: dt(-3600)
      }

      past = %Fixture{
        id: 31,
        round_id: 1,
        team1: "C",
        team2: "D",
        status: :scheduled,
        kickoff_at: dt(-60)
      }

      dash =
        Dashboard.build(
          [round_with(1, :group, [done, past])],
          %{},
          %{entry: nil, rank: 1, of: 1},
          now
        )

      assert Dashboard.next_match(dash, now) == nil
    end
  end
end

defmodule Predictex.DashboardDBTest do
  use Predictex.DataCase, async: true

  import Predictex.AccountsFixtures
  alias Predictex.{Dashboard, Predictions, Tournament}

  defp fixture!(round, attrs) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      team1: "Mexico",
      team2: "Poland",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  test "for_player assembles rounds, picks, points and rank from real data" do
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    player = player_fixture(%{display_name: "Dave"})

    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    completed =
      fixture!(round, %{kickoff_at: past, status: :completed, home_goals: 2, away_goals: 1})

    _open = fixture!(round, %{kickoff_at: future})

    before_kickoff = DateTime.add(past, -1, :second)

    {:ok, _} =
      Predictions.create_prediction(
        %{player_id: player.id, fixture_id: completed.id, home_goals: 2, away_goals: 1},
        before_kickoff
      )

    view = Dashboard.for_player(player)

    assert view.of >= 1
    assert is_integer(view.rank)
    [r1] = view.rounds
    assert length(r1.fixtures) == 2
    scored = Enum.find(r1.fixtures, &(&1.fixture.id == completed.id))
    assert scored.points > 0 and scored.exact?
    unp = Enum.find(r1.fixtures, &(&1.fixture.id != completed.id))
    assert unp.prediction == nil
  end
end
