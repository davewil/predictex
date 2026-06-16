defmodule Predictex.Fifa.CohortTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.Cohort
  alias Predictex.Tournament.Fixture

  defp fixture(id, team1, team2, kickoff) do
    %Fixture{id: id, team1: team1, team2: team2, kickoff_at: kickoff}
  end

  defp fifa_match(id, home, away, date) do
    %{"id" => id, "homeSquadName" => home, "awaySquadName" => away, "date" => date}
  end

  defp rounds(matches), do: [%{"id" => 1, "stage" => "group", "tournaments" => matches}]

  test "maps cohort onto the matching fixture (positional, no swap)" do
    fx = fixture(7, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
    rounds = rounds([fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])
    stats = %{"1" => %{"homeWin" => 52, "draw" => 32, "awayWin" => 16}}

    assert [u] = Cohort.plan(rounds, stats, [fx])
    assert u == %{fixture_id: 7, cohort_home_pct: 52, cohort_draw_pct: 32, cohort_away_pct: 16}
  end

  test "orients home/away when the sources order the pair oppositely (swap)" do
    # Our fixture lists Spain first (home); FIFA lists Iran first (home).
    fx = fixture(9, "Spain", "Iran", ~U[2026-06-20 19:00:00Z])
    rounds = rounds([fifa_match(5, "Iran", "Spain", "2026-06-20T20:00:00+01:00")])
    stats = %{"5" => %{"homeWin" => 30, "draw" => 20, "awayWin" => 50}}

    assert [u] = Cohort.plan(rounds, stats, [fx])
    # cohort_home_pct must be OUR home (Spain) share = FIFA awayWin = 50
    assert u.cohort_home_pct == 50
    assert u.cohort_away_pct == 30
    assert u.cohort_draw_pct == 20
  end

  test "matches across FIFA<->openfootball name aliases" do
    fx = fixture(3, "Iran", "Spain", ~U[2026-06-20 19:00:00Z])
    rounds = rounds([fifa_match(5, "IR Iran", "Spain", "2026-06-20T20:00:00+01:00")])
    stats = %{"5" => %{"homeWin" => 30, "draw" => 20, "awayWin" => 50}}

    assert [u] = Cohort.plan(rounds, stats, [fx])
    assert u.fixture_id == 3
    assert u.cohort_home_pct == 30
  end

  test "omits a FIFA match with no matching fixture" do
    fx = fixture(1, "Brazil", "Serbia", ~U[2026-06-12 19:00:00Z])
    rounds = rounds([fifa_match(9, "France", "Denmark", "2026-06-13T20:00:00+01:00")])
    stats = %{"9" => %{"homeWin" => 40, "draw" => 30, "awayWin" => 30}}

    assert [] = Cohort.plan(rounds, stats, [fx])
  end

  test "omits a FIFA match that has no matchStats entry yet (knockout not open)" do
    fx = fixture(1, "Brazil", "Serbia", ~U[2026-06-12 19:00:00Z])
    rounds = rounds([fifa_match(2, "Brazil", "Serbia", "2026-06-12T20:00:00+01:00")])
    assert [] = Cohort.plan(rounds, %{}, [fx])
  end

  test "resolves a newly-verified alias (Czechia -> Czech Republic)" do
    fx = fixture(11, "Czech Republic", "Spain", ~U[2026-06-22 19:00:00Z])
    rounds = rounds([fifa_match(7, "Czechia", "Spain", "2026-06-22T20:00:00+01:00")])
    stats = %{"7" => %{"homeWin" => 45, "draw" => 25, "awayWin" => 30}}

    assert [u] = Cohort.plan(rounds, stats, [fx])
    assert u.fixture_id == 11
    assert u.cohort_home_pct == 45
  end

  test "omits a match whose matchStats entry has nil percentages" do
    fx = fixture(1, "Brazil", "Serbia", ~U[2026-06-12 19:00:00Z])
    rounds = rounds([fifa_match(2, "Brazil", "Serbia", "2026-06-12T20:00:00+01:00")])
    stats = %{"2" => %{"homeWin" => nil, "draw" => nil, "awayWin" => nil}}
    assert [] = Cohort.plan(rounds, stats, [fx])
  end
end
