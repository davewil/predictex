defmodule Predictex.Results.IngestTest do
  use Predictex.DataCase, async: true

  alias Predictex.Results.Ingest
  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture

  @doc_fixture %{
    "matches" => [
      %{
        "round" => "Matchday 1",
        "date" => "2026-06-11",
        "time" => "13:00 UTC-6",
        "group" => "Group A",
        "team1" => "Mexico",
        "team2" => "South Africa",
        "score" => %{"ft" => [2, 0]},
        "goals1" => [%{"name" => "Quiñones", "minute" => "9"}],
        "goals2" => []
      },
      %{
        "round" => "Round of 16",
        "date" => "2026-07-04",
        "time" => "16:00 UTC-4",
        "team1" => "Brazil",
        "team2" => "Spain"
      }
    ]
  }

  test "sync creates rounds and fixtures with derived fields" do
    summary = Ingest.sync(@doc_fixture)

    assert summary.rounds == 2
    assert summary.fixtures_ok == 2
    assert summary.fixtures_error == 0

    fx = Tournament.get_fixture_by_ref("2026-06-11 Mexico v South Africa")
    assert fx.status == :completed
    assert {fx.home_goals, fx.away_goals} == {2, 0}
    assert fx.first_scorer_side == :home
    assert fx.first_scorer_player == "Quiñones"
    assert fx.kickoff_at == ~U[2026-06-11 19:00:00Z]
    assert Tournament.get_round!(fx.round_id).ordinal == 1
  end

  test "sync is idempotent — re-running does not duplicate" do
    Ingest.sync(@doc_fixture)
    Ingest.sync(@doc_fixture)

    assert length(Tournament.list_fixtures()) == 2
    assert length(Tournament.list_rounds()) == 2
  end

  test "re-sync updates results but preserves admin-entered cohort %" do
    Ingest.sync(@doc_fixture)

    ko = Tournament.get_fixture_by_ref("2026-07-04 Brazil v Spain")
    assert ko.status == :scheduled

    {:ok, _} =
      Tournament.update_fixture(ko, %{
        cohort_home_pct: 55,
        cohort_draw_pct: 25,
        cohort_away_pct: 20
      })

    # A later feed now carries the result for that knockout match.
    doc2 =
      update_in(@doc_fixture, ["matches"], fn [m1, m2] ->
        [m1, Map.put(m2, "score", %{"ft" => [1, 0]})]
      end)

    Ingest.sync(doc2)

    updated = Tournament.get_fixture_by_ref("2026-07-04 Brazil v Spain")
    assert updated.status == :completed
    assert updated.home_goals == 1
    # cohort % was admin-entered and must survive the re-sync
    assert updated.cohort_home_pct == 55
    assert updated.cohort_away_pct == 20
  end

  test "persists goal events and refreshes them on re-sync" do
    doc = %{
      "matches" => [
        %{
          "round" => "Matchday 1",
          "team1" => "Egypt",
          "team2" => "Belgium",
          "date" => "2026-06-20",
          "time" => "18:00",
          "score" => %{"ft" => [2, 1]},
          "goals1" => [%{"name" => "Salah", "minute" => 16, "penalty" => true}],
          "goals2" => [%{"name" => "Lukaku", "minute" => 73}]
        }
      ]
    }

    doc |> Ingest.plan() |> Ingest.commit()
    fx = Repo.get_by!(Fixture, external_ref: "2026-06-20 Egypt v Belgium")

    assert [%{side: :home, type: :penalty, player: "Salah"}, %{side: :away, type: :regular}] =
             fx.goals

    # re-sync with an extra goal → overwritten, not duplicated
    doc2 =
      put_in(doc, ["matches", Access.at(0), "goals2"], [
        %{"name" => "Lukaku", "minute" => 73},
        %{"name" => "Hazard", "minute" => 88}
      ])

    doc2 |> Ingest.plan() |> Ingest.commit()
    fx2 = Repo.get_by!(Fixture, external_ref: "2026-06-20 Egypt v Belgium")
    assert length(fx2.goals) == 3
  end

  test "commit/1 broadcasts a coarse fixture-change so live dashboards re-pull on settle (predictex-9p0)" do
    Tournament.subscribe_changes()
    @doc_fixture |> Ingest.plan() |> Ingest.commit()
    # assert_received: the broadcast is synchronous, so no async timeout window (predictex-9p0).
    assert_received :fixtures_changed
  end

  defp ko_doc(team1, team2, extra \\ %{}) do
    match =
      Map.merge(
        %{
          "round" => "Round of 32",
          "num" => 73,
          "date" => "2026-06-28",
          "time" => "12:00 UTC-7",
          "team1" => team1,
          "team2" => team2
        },
        extra
      )

    %{"matches" => [match]}
  end

  test "knockout team resolution updates the SAME fixture in place via source_num — no duplicate (predictex-g8m)" do
    # Seeded pre-resolution with bracket placeholders, as openfootball publishes them.
    ko_doc("2A", "2B") |> Ingest.plan() |> Ingest.commit()
    seeded = Tournament.get_fixture_by_source_num(73)
    assert seeded.team1 == "2A"
    assert seeded.source_num == 73
    original_id = seeded.id

    # The bracket resolves: openfootball flips the teams on the same match num.
    ko_doc("Brazil", "France", %{"score" => %{"ft" => [2, 1]}})
    |> Ingest.plan()
    |> Ingest.commit()

    # Exactly one fixture for num 73 — the placeholder was UPDATED, not duplicated.
    assert Enum.count(Tournament.list_fixtures(), &(&1.source_num == 73)) == 1

    resolved = Tournament.get_fixture_by_source_num(73)
    assert resolved.id == original_id
    assert resolved.team1 == "Brazil"
    assert resolved.team2 == "France"
    assert resolved.external_ref == "2026-06-28 Brazil v France"
    assert {resolved.home_goals, resolved.away_goals} == {2, 1}
  end

  test "first sync stamps source_num onto a pre-existing placeholder KO fixture via the ref fallback (predictex-g8m bootstrap)" do
    # Simulate prod: a knockout fixture created BEFORE g8m — source_num is NULL, teams still placeholder.
    {:ok, round} =
      Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})

    {:ok, existing} =
      Tournament.create_fixture(%{
        external_ref: "2026-06-28 2A v 2B",
        team1: "2A",
        team2: "2B",
        status: :scheduled,
        kickoff_at: ~U[2026-06-28 19:00:00Z],
        round_id: round.id
      })

    assert existing.source_num == nil

    # The next sync carries num 73 for the same still-placeholder match → stamp in place.
    ko_doc("2A", "2B") |> Ingest.plan() |> Ingest.commit()

    assert Enum.count(Tournament.list_fixtures(), &(&1.external_ref == "2026-06-28 2A v 2B")) == 1
    stamped = Tournament.get_fixture_by_source_num(73)
    assert stamped.id == existing.id
    assert stamped.source_num == 73
  end

  test "a knockout resolution sync preserves FIFA- and cohort-owned columns — two-writer rule on the source_num branch (predictex-g8m)" do
    ko_doc("2A", "2B") |> Ingest.plan() |> Ingest.commit()
    fx = Tournament.get_fixture_by_source_num(73)

    # Simulate the other two writers having populated their columns: CohortSync (cohort %) and the
    # FIFA live-capture pipeline (live_*, is_live, fifa_match_id). A result sync must NOT touch these.
    {:ok, _} =
      fx
      |> Ecto.Changeset.change(%{
        cohort_home_pct: 55,
        live_home_goals: 1,
        live_away_goals: 0,
        live_minute: "30'",
        is_live: true,
        fifa_match_id: "400251073"
      })
      |> Repo.update()

    # Bracket resolves: result sync flips the teams and writes the final score.
    ko_doc("Brazil", "France", %{"score" => %{"ft" => [2, 1]}})
    |> Ingest.plan()
    |> Ingest.commit()

    reloaded = Tournament.get_fixture_by_source_num(73)
    assert reloaded.id == fx.id
    # openfootball-owned fields updated …
    assert reloaded.team1 == "Brazil"
    assert {reloaded.home_goals, reloaded.away_goals} == {2, 1}
    # … while cohort- and FIFA/capture-owned fields are left untouched by the result sync.
    assert reloaded.cohort_home_pct == 55
    assert reloaded.fifa_match_id == "400251073"
    assert reloaded.live_home_goals == 1
    assert reloaded.is_live == true
  end
end
