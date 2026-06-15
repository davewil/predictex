defmodule PredictexWeb.LeaderboardLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Predictex.{Accounts, Predictions, Tournament}

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

    {:ok, dave} = Accounts.create_player(%{display_name: "Dave"})

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
  end
end
