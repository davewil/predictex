defmodule Predictex.Fifa.LiveIdsTest do
  use Predictex.DataCase, async: true
  alias Predictex.Fifa.LiveIds
  alias Predictex.{Repo, Tournament}

  defp ko_round do
    {:ok, r} = Tournament.create_round(%{name: "R32", stage: :knockout, ordinal: 4})
    r
  end

  defp fixture(attrs) do
    {:ok, f} =
      Tournament.create_fixture(
        Map.merge(
          %{external_ref: "ref-#{System.unique_integer([:positive])}", team1: "A", team2: "B"},
          attrs
        )
      )

    Repo.preload(f, :round)
  end

  # One FIFA `rounds.json` knockout match at 2026-06-28 19:00 UTC (the slot the KO tests key on).
  defp r32_round(teams \\ {"Germany", "Brazil"}, fifa_id \\ 400_021_600) do
    {home, away} = teams

    %{
      "stage" => "r32",
      "tournaments" => [
        %{
          "fifaId" => fifa_id,
          "homeSquadName" => home,
          "awaySquadName" => away,
          "date" => "2026-06-28T20:00:00+01:00"
        }
      ]
    }
  end

  test "plan/2 skips fixtures that already have a fifa_match_id" do
    # name AND slot would both match r32_round — the only reason for [] is the already-assigned skip.
    f =
      fixture(%{
        team1: "Germany",
        team2: "Brazil",
        round_id: ko_round().id,
        kickoff_at: ~U[2026-06-28 19:00:00Z],
        fifa_match_id: "already"
      })

    assert [] = LiveIds.plan([r32_round()], [f])
  end

  test "plan/2 falls back to a date+time slot match for a knockout fixture the name-join misses" do
    # Our side still carries bracket placeholders (2A/2B); FIFA has the resolved teams.
    f =
      fixture(%{
        team1: "2A",
        team2: "2B",
        round_id: ko_round().id,
        kickoff_at: ~U[2026-06-28 19:00:00Z]
      })

    assert [%{fixture_id: id, fifa_match_id: "400021600", via: :slot}] =
             LiveIds.plan([r32_round()], [f])

    assert id == f.id
  end

  test "plan/2 does not slot-match a group fixture whose name does not match" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    f =
      fixture(%{
        team1: "TeamX",
        team2: "TeamY",
        round_id: r.id,
        kickoff_at: ~U[2026-06-28 19:00:00Z]
      })

    # FIFA group match at the same slot but different teams — must NOT slot-match (group is not 1:1 per slot).
    rounds = [r32_round() |> Map.put("stage", "group")]
    assert [] = LiveIds.plan(rounds, [f])
  end

  test "plan/2 prefers the name match over the slot fallback for a knockout fixture" do
    f =
      fixture(%{
        team1: "Germany",
        team2: "Brazil",
        round_id: ko_round().id,
        kickoff_at: ~U[2026-06-28 19:00:00Z]
      })

    assert [%{fifa_match_id: "400021600", via: :name}] = LiveIds.plan([r32_round()], [f])
  end

  test "assign/1 writes ids and returns a name/slot summary" do
    # one knockout fixture matched by slot (placeholder teams), one group matched by name.
    #
    # Create the group round (ordinal 1) BEFORE the knockout round (ordinal 4, via ko_round/0).
    # Every async test that inserts rounds must acquire the rounds.ordinal unique-index locks
    # in ascending order: a single descending inserter (high ordinal then low) lets concurrent
    # sandbox transactions form a lock cycle, and PostgreSQL kills one with a deadlock
    # (predictex-dmh). Ascending-everywhere keeps the lock-wait graph acyclic.
    {:ok, gr} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    grp =
      fixture(%{
        team1: "Germany",
        team2: "Brazil",
        round_id: gr.id,
        kickoff_at: ~U[2026-06-11 19:00:00Z]
      })

    ko =
      fixture(%{
        team1: "2A",
        team2: "2B",
        round_id: ko_round().id,
        kickoff_at: ~U[2026-06-28 19:00:00Z]
      })

    rounds = [
      r32_round(),
      %{
        "stage" => "group",
        "tournaments" => [
          %{
            "fifaId" => 400_021_001,
            "homeSquadName" => "Germany",
            "awaySquadName" => "Brazil",
            "date" => "2026-06-11T19:00:00+00:00"
          }
        ]
      }
    ]

    assert %{assigned: 2, by_name: 1, by_slot: 1, errors: 0} = LiveIds.assign(rounds)
    assert Tournament.get_fixture!(ko.id).fifa_match_id == "400021600"
    assert Tournament.get_fixture!(grp.id).fifa_match_id == "400021001"
  end

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
