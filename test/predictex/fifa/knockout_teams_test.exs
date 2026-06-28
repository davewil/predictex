defmodule Predictex.Fifa.KnockoutTeamsTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.KnockoutTeams
  alias Predictex.GroupTables
  alias Predictex.Tournament.Fixture

  # Group I result → France is rank 1 (winner of I), Spain rank 2.
  @tables GroupTables.build([
            %Fixture{
              team1: "France",
              team2: "Spain",
              group: "I",
              status: :completed,
              home_goals: 1,
              away_goals: 0
            }
          ])

  # A FIFA rounds.json R32 entry kicking off at `iso` between FIFA-named home/away.
  defp rounds(iso, home, away) do
    [
      %{
        "stage" => "r32",
        "tournaments" => [%{"date" => iso, "homeSquadName" => home, "awaySquadName" => away}]
      }
    ]
  end

  # Canonical openfootball names already present in our fixtures (group stage has all 48).
  @canon KnockoutTeams.canonical_index([
           "USA",
           "Bosnia & Herzegovina",
           "Brazil",
           "Japan",
           "Mexico"
         ])

  describe "canonical_index/1" do
    test "maps normalized (incl. FIFA alias) names back to the canonical name, skipping placeholders" do
      idx = KnockoutTeams.canonical_index(["Bosnia & Herzegovina", "USA", "3B/E/F/I/J", "1A"])
      # FIFA writes "Bosnia and Herzegovina"; norm aliases it to "bosnia & herzegovina".
      assert idx[Predictex.Fifa.Crosswalk.norm("Bosnia and Herzegovina")] ==
               "Bosnia & Herzegovina"

      assert idx[Predictex.Fifa.Crosswalk.norm("USA")] == "USA"
      # placeholders are not real names → not indexed
      refute Map.has_key?(idx, Predictex.Fifa.Crosswalk.norm("3B/E/F/I/J"))
    end
  end

  describe "plan/3 — one placeholder side, anchored on the resolved side" do
    test "fills the placeholder away side from the FIFA entry matched by slot" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 7, team1: "USA", team2: "3B/E/F/I/J", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "USA", "Bosnia and Herzegovina")

      assert [%{fixture_id: 7, team2: "Bosnia & Herzegovina"} = fill] =
               KnockoutTeams.plan(r, [f], @canon)

      refute Map.has_key?(fill, :team1)
    end

    test "respects FIFA home/away orientation: anchor on the resolved side, fill the other" do
      ko = ~U[2026-07-02 01:00:00Z]

      # Our resolved side is team1=USA, but FIFA lists USA as AWAY → the placeholder team2 gets FIFA's HOME.
      f = %Fixture{id: 8, team1: "USA", team2: "3B/E/F/I/J", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "Bosnia and Herzegovina", "USA")

      assert [%{fixture_id: 8, team2: "Bosnia & Herzegovina"}] =
               KnockoutTeams.plan(r, [f], @canon)
    end
  end

  describe "plan/3 — guards" do
    test "never emits a resolved side (no-downgrade): a fully-resolved fixture yields nothing" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 9, team1: "USA", team2: "Bosnia & Herzegovina", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "Mexico", "Brazil")
      assert KnockoutTeams.plan(r, [f], @canon) == []
    end

    test "skips when no FIFA entry matches the fixture's slot" do
      f = %Fixture{
        id: 10,
        team1: "USA",
        team2: "3B/E/F/I/J",
        kickoff_at: ~U[2026-07-02 01:00:00Z]
      }

      r = rounds("2026-07-03T20:00:00+00:00", "USA", "Bosnia and Herzegovina")
      assert KnockoutTeams.plan(r, [f], @canon) == []
    end

    test "skips a side whose FIFA name is not a known canonical team (no junk written)" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 11, team1: "USA", team2: "3B/E/F/I/J", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "USA", "Atlantis")
      assert KnockoutTeams.plan(r, [f], @canon) == []
    end

    test "both placeholders: no fill (no resolved anchor to validate orientation against)" do
      # Anchored-only (v1): without a resolved side we can't trust FIFA's home/away order, and the
      # codebase deliberately distrusts pair ordering (Crosswalk.match_key is an unordered set;
      # Cohort handles swaps). The group winner resolves first via openfootball, then the anchored
      # case fills the third — so we lose essentially nothing by waiting.
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 12, team1: "1H", team2: "2J", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "Brazil", "Japan")
      assert KnockoutTeams.plan(r, [f], @canon) == []
    end
  end

  describe "plan/4 — both-placeholder (projection-validated orientation, predictex-dum)" do
    test "fills BOTH sides when the winner slot projects to a team matching a FIFA name" do
      ko = ~U[2026-07-02 01:00:00Z]
      # Our fixture: team1 = winner of I (placeholder), team2 = a third (placeholder).
      f = %Fixture{id: 20, team1: "1I", team2: "3C/D/F/G/H", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "France", "Sweden")
      canon = KnockoutTeams.canonical_index(["France", "Sweden", "Spain"])

      assert [%{fixture_id: 20, team1: "France", team2: "Sweden"}] =
               KnockoutTeams.plan(r, [f], canon, @tables)
    end

    test "re-orients when FIFA lists the pair swapped (team1 still gets the winner)" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 21, team1: "1I", team2: "3C/D/F/G/H", kickoff_at: ko}
      # FIFA lists Sweden home, France away — our team1 (1I→France) must still become France.
      r = rounds("2026-07-02T01:00:00+00:00", "Sweden", "France")
      canon = KnockoutTeams.canonical_index(["France", "Sweden"])

      assert [%{fixture_id: 21, team1: "France", team2: "Sweden"}] =
               KnockoutTeams.plan(r, [f], canon, @tables)
    end

    test "orients when the winner slot is on team2 (covers orient_both arms c/d), both FIFA orderings" do
      ko = ~U[2026-07-02 01:00:00Z]
      # The winner placeholder is team2 this time; the third is team1 (which never projects).
      f = %Fixture{id: 26, team1: "3C/D/F/G/H", team2: "1I", kickoff_at: ko}
      canon = KnockoutTeams.canonical_index(["France", "Sweden"])

      # arm (c): 1I→France matches FIFA home → team2 (the winner) must become France.
      r_home = rounds("2026-07-02T01:00:00+00:00", "France", "Sweden")

      assert [%{fixture_id: 26, team1: "Sweden", team2: "France"}] =
               KnockoutTeams.plan(r_home, [f], canon, @tables)

      # arm (d): FIFA lists the pair swapped — 1I→France matches FIFA away → team2 still France.
      r_away = rounds("2026-07-02T01:00:00+00:00", "Sweden", "France")

      assert [%{fixture_id: 26, team1: "Sweden", team2: "France"}] =
               KnockoutTeams.plan(r_away, [f], canon, @tables)
    end

    test "skips when no side projects (group not decided → empty tables)" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 22, team1: "1Z", team2: "3C/D/F/G/H", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "France", "Sweden")
      canon = KnockoutTeams.canonical_index(["France", "Sweden"])

      assert KnockoutTeams.plan(r, [f], canon, @tables) == []
    end

    test "skips when the projected anchor matches neither FIFA name (spurious slot / disagreement)" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 23, team1: "1I", team2: "3C/D/F/G/H", kickoff_at: ko}
      # 1I projects to France, but FIFA's entry is a different pair → skip.
      r = rounds("2026-07-02T01:00:00+00:00", "Brazil", "Japan")
      canon = KnockoutTeams.canonical_index(["France", "Brazil", "Japan"])

      assert KnockoutTeams.plan(r, [f], canon, @tables) == []
    end

    test "all-or-nothing: skips when one FIFA name is not a known canonical team" do
      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 24, team1: "1I", team2: "3C/D/F/G/H", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "France", "Atlantis")
      canon = KnockoutTeams.canonical_index(["France"])

      assert KnockoutTeams.plan(r, [f], canon, @tables) == []
    end

    test "does not anchor on a provisional-tie position" do
      # Group J: two teams level on points/GD/GF → rank-1 row is provisional_tie? → no anchor.
      tied =
        GroupTables.build([
          %Fixture{
            team1: "Argentina",
            team2: "Mexico",
            group: "J",
            status: :completed,
            home_goals: 1,
            away_goals: 1
          }
        ])

      ko = ~U[2026-07-02 01:00:00Z]
      f = %Fixture{id: 25, team1: "1J", team2: "3C/D/F/G/H", kickoff_at: ko}
      r = rounds("2026-07-02T01:00:00+00:00", "Argentina", "Sweden")
      canon = KnockoutTeams.canonical_index(["Argentina", "Sweden"])

      assert KnockoutTeams.plan(r, [f], canon, tied) == []
    end
  end
end
