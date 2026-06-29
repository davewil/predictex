defmodule Predictex.Scoring.StandingsProjectTest do
  use Predictex.DataCase, async: true
  alias Predictex.{Scoring.Standings, Tournament, Predictions}

  import Predictex.AccountsFixtures

  test "project/4 ranks as if the live fixture finished, without persisting" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "x",
        team1: "Portugal",
        team2: "Congo DR",
        round_id: r.id,
        kickoff_at: ~U[2026-06-17 17:00:00Z],
        status: :live,
        live_home_goals: 1,
        live_away_goals: 0
      })

    p = player_fixture(%{display_name: "Ana", email: "a@b.c"})

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: p.id,
        fixture_id: fx.id,
        home_goals: 1,
        away_goals: 0
      })

    # Real leaderboard: fixture not completed -> Ana has 0.
    assert Enum.find(Standings.leaderboard(), &(&1.player_id == p.id)).total == 0

    # Projected at 1-0: Ana's correct outcome + exact score now scores.
    projected = Standings.project(Standings.snapshot(), fx.id, 1, 0)
    assert Enum.find(projected, &(&1.player_id == p.id)).total > 0

    # Not persisted.
    assert Tournament.get_fixture!(fx.id).status == :live
  end

  test "project/5 credits the knockout first-scorer bonus when a scorer pick is supplied (gga)" do
    {:ok, r} = Tournament.create_round(%{name: "R32", stage: :knockout, ordinal: 4})

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "ko1",
        team1: "Brazil",
        team2: "Japan",
        round_id: r.id,
        kickoff_at: ~U[2026-06-29 17:00:00Z],
        status: :live,
        live_home_goals: 1,
        live_away_goals: 0
      })

    p = player_fixture(%{display_name: "Ana", email: "a@b.c"})

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: p.id,
        fixture_id: fx.id,
        home_goals: 1,
        away_goals: 0,
        first_scorer_side: :home,
        first_scorer_player: "Neymar"
      })

    snap = Standings.snapshot()
    pid = p.id

    scoreline_only = Enum.find(Standings.project(snap, fx.id, 1, 0), &(&1.player_id == pid)).total

    with_scorer =
      Enum.find(
        Standings.project(snap, fx.id, 1, 0, %{side: :home, player: "Neymar"}),
        &(&1.player_id == pid)
      ).total

    # first_team (5) + first_player (10), on top of the scoreline projection.
    assert with_scorer == scoreline_only + 15

    # A nil scorer (no pick / group fixture) leaves the projection scoreline-only.
    nil_scorer =
      Enum.find(
        Standings.project(snap, fx.id, 1, 0, %{side: nil, player: nil}),
        &(&1.player_id == pid)
      ).total

    assert nil_scorer == scoreline_only
  end
end
