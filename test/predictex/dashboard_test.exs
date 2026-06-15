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
      breakdown: [%{ordinal: 1, fixture_id: 1, result: %{fixture_total: 50}}]
    }

    view = Dashboard.build(rounds, preds, %{entry: entry, rank: 9, of: 14}, now)

    assert view.rank == 9 and view.of == 14
    assert view.total == 70 and view.fixtures_total == 50 and view.round_bonus_total == 20

    [r1] = view.rounds
    assert r1.active? and r1.round_bonus == 20
    [fc, fl, fo] = r1.fixtures

    assert fc.points == 50 and fc.booster? and fc.exact?
    assert fl.locked? and fl.points == nil and fl.prediction
    assert fo.prediction == nil and fo.locked? == false
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
