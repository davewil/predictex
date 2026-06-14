defmodule Mix.Tasks.Predictex.LeaderboardTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Predictex.Leaderboard, as: Task

  # The task's Decide phase is pure: raw decoded inputs in, rendered lines out, no I/O.
  describe "decide/1 (pure)" do
    test "renders standings from raw openfootball + predictions maps" do
      results_doc = %{
        "matches" => [
          %{
            "round" => "Matchday 1",
            "date" => "2026-06-14",
            "time" => "20:00",
            "group" => "Group A",
            "team1" => "Egypt",
            "team2" => "Belgium",
            "score" => %{"ft" => [1, 2]},
            "goals1" => [],
            "goals2" => []
          }
        ]
      }

      league = %{
        "players" => [
          %{
            "name" => "Dave",
            "predictions" => [
              %{"home_team" => "Egypt", "away_team" => "Belgium", "home" => 1, "away" => 2}
            ]
          }
        ]
      }

      %{lines: lines} = Task.decide(%{league: league, results_doc: results_doc, opts: []})
      text = Enum.join(lines, "\n")

      assert text =~ "Completed fixtures available: 1 of 1"

      # exact score 30; the single-fixture round is complete and fully predicted → +20 bonus → 50
      assert Enum.any?(lines, &(&1 =~ ~r/Dave\s+30\s+20\s+50/))
    end

    test "flags predictions that match no fixture" do
      results_doc = %{"matches" => []}

      league = %{
        "players" => [
          %{
            "name" => "Lou",
            "predictions" => [
              %{"home_team" => "Narnia", "away_team" => "Mordor", "home" => 1, "away" => 1}
            ]
          }
        ]
      }

      %{lines: lines} = Task.decide(%{league: league, results_doc: results_doc, opts: []})
      text = Enum.join(lines, "\n")

      assert text =~ "matched no fixture"
      assert text =~ "Lou: Narnia v Mordor"
    end
  end
end
