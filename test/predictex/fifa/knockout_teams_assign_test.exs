defmodule Predictex.Fifa.KnockoutTeamsAssignTest do
  use Predictex.DataCase, async: true

  alias Predictex.Fifa.KnockoutTeams
  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture

  # Mirror the repo-wide fixture!/2 pattern: flat attrs + auto external_ref.
  defp fixture!(round, attrs) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  defp ko_round! do
    # Group round first (ascending ordinal) so the canonical index has real names to draw on.
    {:ok, grp} = Tournament.create_round(%{name: "Group", stage: :group, ordinal: 1})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    # Seed every team that will appear in the bracket as a real (openfootball-canonical) name.
    for {a, b} <- [{"USA", "Mexico"}, {"Bosnia & Herzegovina", "Brazil"}] do
      fixture!(grp, %{
        team1: a,
        team2: b,
        kickoff_at: past,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })
    end

    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    ko
  end

  defp rounds(iso, home, away) do
    [
      %{
        "stage" => "r32",
        "tournaments" => [%{"date" => iso, "homeSquadName" => home, "awaySquadName" => away}]
      }
    ]
  end

  test "fills a placeholder side, writes it, and reports the summary" do
    ko = ko_round!()
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    fx = fixture!(ko, %{team1: "USA", team2: "3B/E/F/I/J", kickoff_at: future})
    iso = DateTime.to_iso8601(future)

    assert %{resolved: 1, sides: 1, errors: 0} =
             KnockoutTeams.assign(rounds(iso, "USA", "Bosnia and Herzegovina"))

    assert Repo.get!(Fixture, fx.id).team2 == "Bosnia & Herzegovina"
  end

  test "no-downgrade: a divergent FIFA name never overwrites an already-resolved side" do
    ko = ko_round!()
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    fx = fixture!(ko, %{team1: "USA", team2: "Mexico", kickoff_at: future})
    iso = DateTime.to_iso8601(future)

    # FIFA (hypothetically) disagrees — must be ignored; openfootball-resolved names stand.
    assert %{resolved: 0} = KnockoutTeams.assign(rounds(iso, "Brazil", "Japan"))
    reloaded = Repo.get!(Fixture, fx.id)
    assert reloaded.team1 == "USA" and reloaded.team2 == "Mexico"
  end

  test "idempotent: re-running after a fill writes nothing more" do
    ko = ko_round!()
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    fixture!(ko, %{team1: "USA", team2: "3B/E/F/I/J", kickoff_at: future})
    iso = DateTime.to_iso8601(future)
    r = rounds(iso, "USA", "Bosnia and Herzegovina")

    assert %{resolved: 1} = KnockoutTeams.assign(r)
    assert %{resolved: 0} = KnockoutTeams.assign(r)
  end

  test "assign/1 fills a both-placeholder fixture via the group-standings anchor" do
    # Group I result seeds the canonical index AND the standings (France = winner of I).
    {:ok, grp} = Tournament.create_round(%{name: "Group I", stage: :group, ordinal: 1})

    {:ok, _} =
      Tournament.create_fixture(%{
        external_ref: "2026-06-20 France v Spain",
        team1: "France",
        team2: "Spain",
        group: "I",
        status: :completed,
        home_goals: 2,
        away_goals: 0,
        kickoff_at: ~U[2026-06-20 19:00:00Z],
        round_id: grp.id
      })

    # Seed Sweden as a canonical name too (a completed group fixture in another group).
    {:ok, _} =
      Tournament.create_fixture(%{
        external_ref: "2026-06-20 Sweden v Qatar",
        team1: "Sweden",
        team2: "Qatar",
        group: "C",
        status: :completed,
        home_goals: 1,
        away_goals: 0,
        kickoff_at: ~U[2026-06-20 16:00:00Z],
        round_id: grp.id
      })

    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "ko-bothph",
        team1: "1I",
        team2: "3C/D/F/G/H",
        kickoff_at: future,
        round_id: ko.id
      })

    iso = DateTime.to_iso8601(future)

    rounds = [
      %{
        "stage" => "r32",
        "tournaments" => [
          %{"date" => iso, "homeSquadName" => "France", "awaySquadName" => "Sweden"}
        ]
      }
    ]

    assert %{resolved: 1} = KnockoutTeams.assign(rounds)
    reloaded = Tournament.get_fixture!(fx.id)
    assert reloaded.team1 == "France" and reloaded.team2 == "Sweden"
  end
end
