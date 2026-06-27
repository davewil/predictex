defmodule Predictex.Workers.KnockoutTeamsTest do
  # async: false — this test and my_predictions_live_test both set the process-global
  # :ko_teams_rounds_fun Application key; running sync keeps it out of the concurrent pool so
  # the two can't race (a delete_env between a put_env and the worker's get_env would fall back
  # to a live FIFA fetch / a cross-test stub would slot-mismatch). predictex-e5o final review.
  use Predictex.DataCase, async: false

  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture
  alias Predictex.Workers.KnockoutTeams, as: Worker

  setup do
    on_exit(fn -> Application.delete_env(:predictex, :ko_teams_rounds_fun) end)
    :ok
  end

  defp stub_rounds(fun), do: Application.put_env(:predictex, :ko_teams_rounds_fun, fun)

  defp unique_ref, do: "ref-#{System.unique_integer([:positive])}"

  defp seeded_ko_fixture do
    {:ok, grp} = Tournament.create_round(%{name: "Group", stage: :group, ordinal: 1})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    {:ok, _} =
      Tournament.create_fixture(%{
        external_ref: unique_ref(),
        round_id: grp.id,
        team1: "USA",
        team2: "Bosnia & Herzegovina",
        kickoff_at: past,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })

    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: unique_ref(),
        round_id: ko.id,
        team1: "USA",
        team2: "3B/E/F/I/J",
        kickoff_at: future
      })

    {fx, DateTime.to_iso8601(future)}
  end

  test "fetches and fills when a knockout fixture has a placeholder side" do
    {fx, iso} = seeded_ko_fixture()

    stub_rounds(fn ->
      {:ok,
       [
         %{
           "stage" => "r32",
           "tournaments" => [
             %{
               "date" => iso,
               "homeSquadName" => "USA",
               "awaySquadName" => "Bosnia and Herzegovina"
             }
           ]
         }
       ]}
    end)

    assert :ok = Worker.perform(%Oban.Job{args: %{}})
    assert Repo.get!(Fixture, fx.id).team2 == "Bosnia & Herzegovina"
  end

  test "stop-before-fetch: no network call when every knockout fixture is fully resolved" do
    {:ok, grp} = Tournament.create_round(%{name: "Group", stage: :group, ordinal: 1})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    {:ok, _} =
      Tournament.create_fixture(%{
        external_ref: unique_ref(),
        round_id: grp.id,
        team1: "USA",
        team2: "Mexico",
        kickoff_at: past,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })

    {:ok, ko} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {:ok, _} =
      Tournament.create_fixture(%{
        external_ref: unique_ref(),
        round_id: ko.id,
        team1: "USA",
        team2: "Mexico",
        kickoff_at: future
      })

    stub_rounds(fn -> raise "must not fetch when nothing is pending" end)
    assert :ok = Worker.perform(%Oban.Job{args: %{}})
  end
end
