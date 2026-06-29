defmodule Predictex.LiveScore.BuzzTest do
  # Pure tests: Buzz runs over a hand-built `Standings.Snapshot` and never touches the DB,
  # so there is no DataCase / Repo here. The zero-DB setup is itself the proof that Buzz no
  # longer loads per projection. Full wiring (snapshot load → Buzz → render) is covered by
  # the DB-backed FixtureLive integration tests.
  use ExUnit.Case, async: true

  alias Predictex.LiveScore.Buzz
  alias Predictex.Scoring.Standings
  alias Predictex.Scoring.Standings.Snapshot
  alias Predictex.Accounts.Player
  alias Predictex.Predictions.Prediction
  alias Predictex.Tournament.{Fixture, Round}

  @fx_id 10
  @completed_id 20

  setup do
    # One group round with a live fixture (@fx_id) and a completed fixture (@completed_id).
    # Bob predicts the completed fixture 3-1 vs actual 1-0: correct outcome, wrong goals → 10
    # base pts. Ana predicts the live fixture 1-0 (not yet completed) → 0 base pts. Each predicted
    # only one of the round's two fixtures, so neither earns a round bonus in any projection.
    # Base ranks: Bob #1 (10), Ana #2 (0). Project the live fixture to 1-0 (home_next / Ana's
    # pick) → Ana earns her exact 30 and overtakes Bob.
    round = %Round{id: 1, ordinal: 1, stage: :group}

    fx = %Fixture{id: @fx_id, status: :live, home_goals: nil, away_goals: nil, round: round}

    completed_fx = %Fixture{
      id: @completed_id,
      status: :completed,
      home_goals: 1,
      away_goals: 0,
      round: round
    }

    ana = %Player{
      id: 1,
      display_name: "Ana",
      predictions: [%Prediction{fixture_id: @fx_id, home_goals: 1, away_goals: 0}]
    }

    bob = %Player{
      id: 2,
      display_name: "Bob",
      predictions: [%Prediction{fixture_id: @completed_id, home_goals: 3, away_goals: 1}]
    }

    snapshot = %Snapshot{players: [ana, bob], fixtures: [fx, completed_fx]}

    %{snapshot: snapshot, ana: ana, bob: bob}
  end

  test "scenarios/4 returns the three what-if leaderboards", %{snapshot: snap} do
    keys = Buzz.scenarios(snap, @fx_id, 0, 0) |> Enum.map(& &1.key)
    assert keys == [:end_now, :home_next, :away_next]
  end

  test "narratives mention the viewer with 'you' framing", %{snapshot: snap, ana: ana} do
    lines = Buzz.narratives(snap, @fx_id, 0, 0, ana.id)
    assert Enum.any?(lines, &String.contains?(&1, "you"))
  end

  test "scenarios_with_deltas/4 rows carry rank, prev_rank and delta", %{
    snapshot: snap,
    ana: ana
  } do
    # Base: Bob #1 (10), Ana #2 (0). In :home_next (1-0) Ana earns 30 → #1, Bob #2.
    # Ana's delta = prev_rank(2) - rank(1) = +1.
    result = Buzz.scenarios_with_deltas(snap, @fx_id, 0, 0)
    home_next = Enum.find(result, &(&1.key == :home_next))
    assert home_next != nil

    ana_row = Enum.find(home_next.rows, &(&1.player_id == ana.id))
    assert ana_row.rank == 1
    assert ana_row.prev_rank == 2
    assert ana_row.delta == 1
  end

  test "headlines/5 includes a movement line and renders 'you' for the viewer", %{
    snapshot: snap,
    ana: ana,
    bob: bob
  } do
    lines = Buzz.headlines(snap, @fx_id, 0, 0, ana.id)

    assert lines != []
    assert Enum.any?(lines, &String.contains?(&1, "you"))

    assert Enum.any?(
             lines,
             &(String.contains?(&1, "overtake") or String.contains?(&1, "moves up to #"))
           )

    assert Enum.any?(lines, &String.contains?(&1, bob.display_name))
  end

  describe "pick_projection/5 (kcx — 'if your pick lands')" do
    test "projects the board as if the fixture finished the given scoreline", %{
      snapshot: snap,
      ana: ana,
      bob: bob
    } do
      %{rows: rows} = Buzz.pick_projection(snap, @fx_id, 1, 0, ana.id)

      ana_row = Enum.find(rows, &(&1.player_id == ana.id))
      bob_row = Enum.find(rows, &(&1.player_id == bob.id))

      assert ana_row.total == 30
      assert ana_row.rank == 1
      assert bob_row.rank == 2

      # Cross-check against the underlying projection — no duplicated scoring math.
      [top | _] = Standings.project(snap, @fx_id, 1, 0)
      assert top.player_id == ana.id and top.total == 30
    end

    test "viewer row carries rank, prev_rank and delta vs current standings", %{
      snapshot: snap,
      ana: ana
    } do
      %{viewer: viewer} = Buzz.pick_projection(snap, @fx_id, 1, 0, ana.id)

      assert viewer.player_id == ana.id
      assert viewer.rank == 1
      assert viewer.prev_rank == 2
      assert viewer.delta == 1
    end

    test "returns the rows + viewer shape", %{snapshot: snap, ana: ana} do
      assert %{rows: rows, viewer: viewer} = Buzz.pick_projection(snap, @fx_id, 1, 0, ana.id)
      assert is_list(rows)
      assert viewer.player_id == ana.id
    end
  end
end
