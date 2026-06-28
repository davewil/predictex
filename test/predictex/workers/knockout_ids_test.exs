defmodule Predictex.Workers.KnockoutIdsTest do
  use Predictex.DataCase, async: true
  use Oban.Testing, repo: Predictex.Repo

  alias Predictex.Tournament
  alias Predictex.Workers.KnockoutIds

  defp ko_round do
    Tournament.get_round_by_ordinal(4) ||
      (
        {:ok, r} = Tournament.create_round(%{name: "R32", stage: :knockout, ordinal: 4})
        r
      )
  end

  defp ko_fixture(attrs) do
    {:ok, f} =
      Tournament.create_fixture(
        Map.merge(
          %{
            external_ref: "ref-#{System.unique_integer([:positive])}",
            team1: "A",
            team2: "B",
            round_id: ko_round().id,
            kickoff_at: ~U[2026-06-28 19:00:00Z]
          },
          attrs
        )
      )

    f
  end

  defp put_rounds_fun(fun) do
    Application.put_env(:predictex, :ko_ids_rounds_fun, fun)
    on_exit(fn -> Application.put_env(:predictex, :ko_ids_rounds_fun, fn -> {:ok, []} end) end)
  end

  test "perform no-ops without fetching when every knockout fixture has both a fifa_match_id and stage" do
    ko_fixture(%{fifa_match_id: "already", fifa_stage_id: "289287"})
    test_pid = self()

    put_rounds_fun(fn ->
      send(test_pid, :fetched)
      {:ok, []}
    end)

    assert :ok = perform_job(KnockoutIds, %{})
    refute_received :fetched
  end

  test "perform fetches and backfills fifa_stage_id for a knockout fixture that has an id but no stage" do
    # The latent bug: a KO fixture was assigned a fifa_match_id before the stage column existed,
    # so live capture addressed the wrong (group) stage. The stop-before-fetch guard must fire on a
    # MISSING STAGE too (not just a missing id), or these fixtures never get their stage.
    f = ko_fixture(%{team1: "Germany", team2: "Brazil", fifa_match_id: "400021600"})

    rounds = [
      %{
        "stage" => "r32",
        "tournaments" => [
          %{
            "fifaId" => 400_021_600,
            "homeSquadName" => "Germany",
            "awaySquadName" => "Brazil",
            "date" => "2026-06-28T20:00:00+01:00",
            "matchcentreUrl" =>
              "https://www.fifa.com/fifaplus/en/match-centre/match/17/285023/289287/400021600?gender=2"
          }
        ]
      }
    ]

    put_rounds_fun(fn -> {:ok, rounds} end)

    assert :ok = perform_job(KnockoutIds, %{})
    assert %{fifa_match_id: "400021600", fifa_stage_id: "289287"} = Tournament.get_fixture!(f.id)
  end

  test "perform fetches rounds and backfills a knockout fixture missing its fifa_match_id (via the slot fallback)" do
    # Our side still carries bracket placeholders; the slot fallback matches by kickoff.
    f = ko_fixture(%{team1: "2A", team2: "2B", kickoff_at: ~U[2026-06-28 19:00:00Z]})

    rounds = [
      %{
        "stage" => "r32",
        "tournaments" => [
          %{
            "fifaId" => 400_021_600,
            "homeSquadName" => "Germany",
            "awaySquadName" => "Brazil",
            "date" => "2026-06-28T20:00:00+01:00"
          }
        ]
      }
    ]

    put_rounds_fun(fn -> {:ok, rounds} end)

    assert :ok = perform_job(KnockoutIds, %{})
    assert %{fifa_match_id: "400021600"} = Tournament.get_fixture!(f.id)
  end

  test "perform returns the error when the rounds fetch fails (so Oban retries)" do
    ko_fixture(%{})
    put_rounds_fun(fn -> {:error, :boom} end)

    assert {:error, :boom} = perform_job(KnockoutIds, %{})
  end
end
