defmodule Predictex.Fifa.KnockoutTeamsTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.KnockoutTeams
  alias Predictex.Tournament.Fixture

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
end
