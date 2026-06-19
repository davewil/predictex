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
end
