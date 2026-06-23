defmodule Predictex.Results.FifaFallbackTest do
  use Predictex.DataCase, async: true

  alias Predictex.Results.FifaFallback
  alias Predictex.Results.Ingest
  alias Predictex.Tournament

  defp group_fixture(status \\ :scheduled),
    do: %{round: %{stage: :group}, status: status}

  defp finished_body(h, a),
    do: %{"MatchStatus" => 0, "HomeTeam" => %{"Score" => h}, "AwayTeam" => %{"Score" => a}}

  test "settles an unsettled group fixture from a finished frame" do
    assert {:ok, %{status: :completed, home_goals: 3, away_goals: 0}} =
             FifaFallback.settle_attrs(group_fixture(), finished_body(3, 0))
  end

  test "skips when the match is not finished (MatchStatus 3)" do
    body = %{"MatchStatus" => 3, "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{"Score" => 0}}
    assert :skip = FifaFallback.settle_attrs(group_fixture(), body)
  end

  test "skips when a score is missing" do
    body = %{"MatchStatus" => 0, "HomeTeam" => %{"Score" => 1}, "AwayTeam" => %{}}
    assert :skip = FifaFallback.settle_attrs(group_fixture(), body)
  end

  test "skips a knockout fixture (ET/penalties out of scope)" do
    ko = %{round: %{stage: :knockout}, status: :scheduled}
    assert :skip = FifaFallback.settle_attrs(ko, finished_body(1, 0))
  end

  test "skips an already-completed fixture" do
    assert :skip = FifaFallback.settle_attrs(group_fixture(:completed), finished_body(3, 0))
  end

  test "skips when there is no captured body" do
    assert :skip = FifaFallback.settle_attrs(group_fixture(), nil)
  end

  defp db_group_fixture(attrs) do
    round =
      Tournament.get_round_by_ordinal(1) ||
        (
          {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})
          r
        )

    {:ok, f} =
      Tournament.create_fixture(
        Map.merge(
          %{
            external_ref: "ref-#{System.unique_integer([:positive])}",
            team1: "A",
            team2: "B",
            round_id: round.id,
            kickoff_at: DateTime.add(DateTime.utc_now(), -200 * 60)
          },
          attrs
        )
      )

    f
  end

  defp put_body_fun(map) do
    Application.put_env(:predictex, :fifa_fallback_body_fun, fn id -> Map.get(map, id) end)
    on_exit(fn -> Application.delete_env(:predictex, :fifa_fallback_body_fun) end)
  end

  describe "run/0" do
    test "settles an eligible candidate and leaves others alone" do
      eligible = db_group_fixture(%{fifa_match_id: "100", status: :scheduled})
      not_finished = db_group_fixture(%{fifa_match_id: "101", status: :scheduled})

      already =
        db_group_fixture(%{
          fifa_match_id: "102",
          status: :completed,
          home_goals: 1,
          away_goals: 1
        })

      put_body_fun(%{
        "100" => %{
          "MatchStatus" => 0,
          "HomeTeam" => %{"Score" => 3},
          "AwayTeam" => %{"Score" => 0}
        },
        "101" => %{
          "MatchStatus" => 3,
          "HomeTeam" => %{"Score" => 1},
          "AwayTeam" => %{"Score" => 0}
        },
        "102" => %{
          "MatchStatus" => 0,
          "HomeTeam" => %{"Score" => 5},
          "AwayTeam" => %{"Score" => 5}
        }
      })

      assert %{settled: 1} = FifaFallback.run()

      assert %{status: :completed, home_goals: 3, away_goals: 0} =
               Tournament.get_fixture!(eligible.id)

      assert %{status: :scheduled} = Tournament.get_fixture!(not_finished.id)
      # already-completed is untouched by the fallback (1-1 stays, not 5-5)
      assert %{home_goals: 1, away_goals: 1} = Tournament.get_fixture!(already.id)
    end

    test "does not settle a fixture whose kickoff is inside the cutoff window" do
      recent =
        db_group_fixture(%{
          fifa_match_id: "300",
          status: :scheduled,
          kickoff_at: DateTime.add(DateTime.utc_now(), -50 * 60)
        })

      put_body_fun(%{
        "300" => %{
          "MatchStatus" => 0,
          "HomeTeam" => %{"Score" => 2},
          "AwayTeam" => %{"Score" => 1}
        }
      })

      assert %{candidates: 0, settled: 0} = FifaFallback.run()
      assert %{status: :scheduled} = Tournament.get_fixture!(recent.id)
    end

    test "full-tick durability: fallback settle survives a subsequent no-result openfootball sync" do
      # France-v-Iraq scenario: FIFA fallback settles the fixture; a later openfootball sync
      # carries no score for it — the Ingest no-downgrade guard must preserve the result.
      _fixture =
        db_group_fixture(%{
          team1: "Mexico",
          team2: "South Africa",
          external_ref: "2026-06-11 Mexico v South Africa",
          fifa_match_id: "400",
          status: :scheduled,
          kickoff_at: DateTime.add(DateTime.utc_now(), -200 * 60)
        })

      put_body_fun(%{
        "400" => %{
          "MatchStatus" => 0,
          "HomeTeam" => %{"Score" => 3},
          "AwayTeam" => %{"Score" => 0}
        }
      })

      assert %{settled: 1} = FifaFallback.run()

      # Openfootball sync: same fixture listed but with no score (nil).
      Ingest.sync(%{
        "matches" => [
          %{
            "round" => "Matchday 1",
            "date" => "2026-06-11",
            "time" => "13:00 UTC-6",
            "group" => "Group A",
            "team1" => "Mexico",
            "team2" => "South Africa",
            "score" => nil
          }
        ]
      })

      # Reload via external_ref — the no-downgrade guard must keep the fallback result intact.
      reloaded = Tournament.get_fixture_by_ref("2026-06-11 Mexico v South Africa")
      assert reloaded.status == :completed
      assert {reloaded.home_goals, reloaded.away_goals} == {3, 0}
    end

    test "broadcasts a change when something settles" do
      db_group_fixture(%{fifa_match_id: "200", status: :scheduled})
      Tournament.subscribe_changes()

      put_body_fun(%{
        "200" => %{
          "MatchStatus" => 0,
          "HomeTeam" => %{"Score" => 1},
          "AwayTeam" => %{"Score" => 0}
        }
      })

      FifaFallback.run()
      assert_received :fixtures_changed
    end
  end
end
