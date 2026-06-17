defmodule Predictex.Fifa.LiveIdsTest do
  use Predictex.DataCase, async: true
  alias Predictex.Fifa.LiveIds
  alias Predictex.Tournament

  test "plan/2 matches rounds.json fifaId to fixtures by date+teams" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "x",
        team1: "Portugal",
        team2: "Congo DR",
        round_id: r.id,
        kickoff_at: ~U[2026-06-17 17:00:00Z]
      })

    rounds = [
      %{
        "tournaments" => [
          %{
            "fifaId" => 400_021_502,
            "homeSquadName" => "Portugal",
            "awaySquadName" => "Congo DR",
            "date" => "2026-06-17T18:00:00+01:00"
          }
        ]
      }
    ]

    assert [%{fixture_id: id, fifa_match_id: "400021502"}] = LiveIds.plan(rounds, [f])
    assert id == f.id
  end
end
