defmodule Predictex.LeaderboardTest do
  use ExUnit.Case, async: true

  alias Predictex.Leaderboard

  defp fx(attrs) do
    Map.merge(
      %{
        round: "Matchday 1",
        stage: :group,
        team1: "A",
        team2: "B",
        group: "Group A",
        date: "2026-06-11",
        time: "13:00",
        status: :completed,
        home_goals: 0,
        away_goals: 0,
        first_scorer_side: nil,
        first_scorer_player: nil,
        first_goal_owngoal: false
      },
      Map.new(attrs)
    )
  end

  defp player(name, predictions), do: %{name: name, predictions: predictions}

  describe "fixture scoring" do
    test "scores a single exact-score prediction" do
      fixtures = [fx(%{team1: "Egypt", team2: "Belgium", home_goals: 1, away_goals: 2})]
      players = [player("Dave", [%{home_team: "Egypt", away_team: "Belgium", home: 1, away: 2}])]

      assert [%{fixtures_total: 30}] = Leaderboard.build(fixtures, players)
    end

    test "team-name matching is case/whitespace insensitive" do
      fixtures = [fx(%{team1: "Egypt", team2: "Belgium", home_goals: 1, away_goals: 2})]

      players = [
        player("Dave", [%{home_team: "  egypt ", away_team: "BELGIUM", home: 1, away: 2}])
      ]

      assert [%{fixtures_total: 30}] = Leaderboard.build(fixtures, players)
    end

    test "cohort drives the risky bonus" do
      fixtures = [fx(%{team1: "Egypt", team2: "Belgium", home_goals: 0, away_goals: 1})]
      cohort = [%{home_team: "Egypt", away_team: "Belgium", home: 70, draw: 20, away: 10}]
      players = [player("Dave", [%{home_team: "Egypt", away_team: "Belgium", home: 0, away: 1}])]

      # exact away win = 30, plus risky (away cohort 10 < 20) = +10
      assert [%{fixtures_total: 40}] = Leaderboard.build(fixtures, players, cohort)
    end

    test "booster doubles the fixture total" do
      fixtures = [fx(%{team1: "Egypt", team2: "Belgium", home_goals: 1, away_goals: 2})]

      players = [
        player("Dave", [
          %{home_team: "Egypt", away_team: "Belgium", home: 1, away: 2, booster: true}
        ])
      ]

      assert [%{fixtures_total: 60}] = Leaderboard.build(fixtures, players)
    end

    test "knockout prediction scores first-team and first-player components" do
      fixtures = [
        fx(%{
          team1: "Argentina",
          team2: "France",
          round: "Final",
          stage: :knockout,
          home_goals: 1,
          away_goals: 0,
          first_scorer_side: :home,
          first_scorer_player: "Messi"
        })
      ]

      players = [
        player("Dave", [
          %{
            home_team: "Argentina",
            away_team: "France",
            home: 1,
            away: 0,
            first_scorer_side: "home",
            first_scorer_player: "Messi"
          }
        ])
      ]

      # exact 1-0 (30) + first team (5) + first player (10) = 45
      assert [%{fixtures_total: 45}] = Leaderboard.build(fixtures, players)
    end

    test "unpredicted and scheduled fixtures are not scored" do
      fixtures = [
        fx(%{team1: "Egypt", team2: "Belgium", home_goals: 1, away_goals: 2}),
        fx(%{team1: "Brazil", team2: "Spain", group: "Group L", status: :scheduled})
      ]

      players = [
        player("Dave", [
          %{home_team: "Egypt", away_team: "Belgium", home: 1, away: 2},
          %{home_team: "Brazil", away_team: "Spain", home: 0, away: 0}
        ])
      ]

      [dave] = Leaderboard.build(fixtures, players)
      assert dave.fixtures_total == 30
      assert length(dave.breakdown) == 1
    end

    test "ranks players by total descending, ties broken by name" do
      fixtures = [fx(%{team1: "Egypt", team2: "Belgium", home_goals: 1, away_goals: 2})]

      players = [
        player("Exact", [%{home_team: "Egypt", away_team: "Belgium", home: 1, away: 2}]),
        # 0-3 is an away win (correct outcome) but a different goal difference, so +10 only
        player("Outcome", [%{home_team: "Egypt", away_team: "Belgium", home: 0, away: 3}])
      ]

      [first, second] = Leaderboard.build(fixtures, players)
      assert first.name == "Exact" and first.fixtures_total == 30
      assert second.name == "Outcome" and second.fixtures_total == 10
    end
  end

  describe "round bonus (over a 4-team group's Round 1)" do
    # Group A, Round 1 = {A v B, C v D}; later rounds scheduled.
    defp group_a(round1_status) do
      [
        fx(%{
          group: "Group A",
          date: "2026-06-11",
          time: "13:00",
          team1: "A",
          team2: "B",
          home_goals: 1,
          away_goals: 0,
          status: round1_status
        }),
        fx(%{
          group: "Group A",
          date: "2026-06-11",
          time: "20:00",
          team1: "C",
          team2: "D",
          home_goals: 2,
          away_goals: 2,
          status: round1_status
        }),
        fx(%{
          group: "Group A",
          date: "2026-06-15",
          time: "13:00",
          team1: "A",
          team2: "C",
          status: :scheduled
        }),
        fx(%{
          group: "Group A",
          date: "2026-06-15",
          time: "20:00",
          team1: "B",
          team2: "D",
          status: :scheduled
        }),
        fx(%{
          group: "Group A",
          date: "2026-06-19",
          time: "13:00",
          team1: "A",
          team2: "D",
          status: :scheduled
        }),
        fx(%{
          group: "Group A",
          date: "2026-06-19",
          time: "20:00",
          team1: "B",
          team2: "C",
          status: :scheduled
        })
      ]
    end

    test "awards +20 when a complete round is fully and correctly predicted" do
      players = [
        player("Dave", [
          %{home_team: "A", away_team: "B", home: 1, away: 0},
          %{home_team: "C", away_team: "D", home: 2, away: 2}
        ])
      ]

      [dave] = Leaderboard.build(group_a(:completed), players)
      assert dave.fixtures_total == 60
      assert dave.round_bonus_total == 20
      assert dave.total == 80
    end

    test "no bonus when a fixture in the round is left unpredicted" do
      players = [player("Dave", [%{home_team: "A", away_team: "B", home: 1, away: 0}])]

      [dave] = Leaderboard.build(group_a(:completed), players)
      assert dave.fixtures_total == 30
      assert dave.round_bonus_total == 0
    end

    test "no bonus when an outcome in the round is wrong" do
      players = [
        player("Dave", [
          # A v B predicted as an away win — wrong outcome
          %{home_team: "A", away_team: "B", home: 0, away: 1},
          %{home_team: "C", away_team: "D", home: 2, away: 2}
        ])
      ]

      [dave] = Leaderboard.build(group_a(:completed), players)
      assert dave.round_bonus_total == 0
    end

    test "no bonus when the round is incomplete" do
      players = [
        player("Dave", [
          %{home_team: "A", away_team: "B", home: 1, away: 0},
          %{home_team: "C", away_team: "D", home: 2, away: 2}
        ])
      ]

      # Round 1 still has a fixture not completed
      fixtures =
        group_a(:completed)
        |> Enum.map(fn f ->
          if {f.team1, f.team2} == {"C", "D"}, do: %{f | status: :scheduled}, else: f
        end)

      [dave] = Leaderboard.build(fixtures, players)
      assert dave.round_bonus_total == 0
    end
  end
end
