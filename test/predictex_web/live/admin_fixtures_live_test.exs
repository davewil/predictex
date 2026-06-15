defmodule PredictexWeb.AdminFixturesLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.Tournament

  defp fixture!(round, attrs \\ %{}) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      team1: "Brazil",
      team2: "Serbia",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  setup %{conn: conn} do
    admin = admin_player_fixture()
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    %{conn: log_in_player(conn, admin), round: round}
  end

  test "shows 'cohort not set' when a fixture has no cohort percentages", %{
    conn: conn,
    round: round
  } do
    _f = fixture!(round)
    {:ok, _lv, html} = live(conn, ~p"/admin/fixtures")
    assert html =~ "cohort not set"
  end

  test "admin records a result and it persists", %{conn: conn, round: round} do
    f = fixture!(round)
    {:ok, lv, _} = live(conn, ~p"/admin/fixtures")

    lv
    |> form("#fixture-#{f.id}-result",
      fixture: %{home_goals: "2", away_goals: "1", status: "completed"}
    )
    |> render_submit()

    reloaded = Tournament.get_fixture!(f.id)
    assert reloaded.home_goals == 2
    assert reloaded.away_goals == 1
    assert reloaded.status == :completed
  end

  test "admin sets cohort percentages and they persist", %{conn: conn, round: round} do
    f = fixture!(round)
    {:ok, lv, _} = live(conn, ~p"/admin/fixtures")

    lv
    |> form("#fixture-#{f.id}-cohort",
      fixture: %{cohort_home_pct: "50", cohort_draw_pct: "30", cohort_away_pct: "20"}
    )
    |> render_submit()

    reloaded = Tournament.get_fixture!(f.id)
    assert reloaded.cohort_home_pct == 50
    assert reloaded.cohort_draw_pct == 30
    assert reloaded.cohort_away_pct == 20
  end

  test "the sync button runs without hitting the network and reports completion", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/admin/fixtures")
    lv |> element("button", "Sync from feed") |> render_click()
    assert render_async(lv) =~ "Sync complete"
  end
end
