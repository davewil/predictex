defmodule PredictexWeb.LeaderboardLiveTest do
  # async: false retained pending a separate async-safety review (predictex-uhf follow-up);
  # live_buzz was contracted away (live fixtures show unconditionally), so no flag state here.
  use PredictexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Predictex.AccountsFixtures

  alias Predictex.{Predictions, Tournament}

  test "shows an empty state when there are no players", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "Leaderboard"
    assert html =~ "No players yet"
  end

  test "renders ranked standings once players have scored", %{conn: conn} do
    {:ok, round} = Tournament.create_round(%{name: "Round 1", stage: :group, ordinal: 1})

    {:ok, fixture} =
      Tournament.create_fixture(%{
        external_ref: "f1",
        team1: "Egypt",
        team2: "Belgium",
        status: :completed,
        home_goals: 1,
        away_goals: 2,
        round_id: round.id
      })

    dave = player_fixture(%{display_name: "Dave"})

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: dave.id,
        fixture_id: fixture.id,
        home_goals: 1,
        away_goals: 2
      })

    {:ok, _lv, html} = live(conn, ~p"/")

    assert html =~ "Dave"
    # exact score 30 + single-fixture round bonus 20 = 50
    assert html =~ "50"
    assert html =~ "Copy WhatsApp text"
    refute html =~ "No players yet"

    # champion breakdown labels the points correctly: 30 are from regular fixture scoring,
    # 20 from the round bonus. Regression: the card used to read "30 fixtures", which reads as
    # a count of fixtures rather than a points total.
    assert html =~ "30 from fixtures · 20 bonus"
    refute html =~ "30 fixtures ·"
    # no live fixtures here — the "Live now" card must be absent
    refute html =~ "Live now"
  end

  test "shows a Live now card linking to the drill-down", %{conn: conn} do
    {:ok, round} = Tournament.create_round(%{name: "Group A", stage: :group, ordinal: 1})

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "live-lb-#{System.unique_integer([:positive])}",
        team1: "Brazil",
        team2: "Argentina",
        round_id: round.id,
        status: :live,
        is_live: true,
        live_home_goals: 1,
        live_away_goals: 0
      })

    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ "Live now"
    assert html =~ "/fixtures/#{fx.id}"
  end
end
