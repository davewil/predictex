defmodule Predictex.Workers.CohortSyncTest do
  use Predictex.DataCase, async: true
  use Oban.Testing, repo: Predictex.Repo

  alias Predictex.{Scoring.Engine, Tournament}
  alias Predictex.Predictions.SavedPrediction
  alias Predictex.Workers.CohortSync

  defp put_source(fun) do
    Application.put_env(:predictex, :cohort_source_fun, fun)
    on_exit(fn -> Application.delete_env(:predictex, :cohort_source_fun) end)
  end

  test "applies FIFA cohort to the matching fixture and the risky bonus then fires" do
    {:ok, round} = Tournament.create_round(%{name: "Round 1", stage: :group, ordinal: 1})

    {:ok, fixture} =
      Tournament.create_fixture(%{
        external_ref: "ref-1",
        team1: "Mexico",
        team2: "South Africa",
        status: :completed,
        home_goals: 2,
        away_goals: 0,
        kickoff_at: ~U[2026-06-11 19:00:00Z],
        round_id: round.id
      })

    rounds = [
      %{
        "id" => 1,
        "stage" => "group",
        "tournaments" => [
          %{
            "id" => 1,
            "homeSquadName" => "Mexico",
            "awaySquadName" => "South Africa",
            "date" => "2026-06-11T20:00:00+01:00"
          }
        ]
      }
    ]

    stats = %{"1" => %{"homeWin" => 15, "draw" => 30, "awayWin" => 55}}
    put_source(fn -> {:ok, %{rounds: rounds, match_stats: stats}} end)

    assert :ok = perform_job(CohortSync, %{})

    f = Tournament.get_fixture!(fixture.id)
    assert f.cohort_home_pct == 15
    assert f.cohort_draw_pct == 30
    assert f.cohort_away_pct == 55

    # A correct home-win pick whose cohort share (15) is below the risky threshold (20)
    # now earns the risky bonus that was previously skipped (cohort was nil).
    pred = %SavedPrediction{home_goals: 1, away_goals: 0, booster: false}
    assert Engine.score(pred, f, :group).components.risky_bonus == 10
  end

  test "returns {:error, reason} when the source fails (so Oban retries)" do
    put_source(fn -> {:error, :boom} end)
    assert {:error, :boom} = perform_job(CohortSync, %{})
  end
end
