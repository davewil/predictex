defmodule PredictexWeb.AdminPredictionsLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.{Predictions, Tournament}

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
    player = player_fixture(%{display_name: "Dave"})
    %{conn: log_in_player(conn, admin), round: round, player: player}
  end

  # The by-player grid (#by-player-form) only renders after a player + round are
  # selected, so each entry test first fires load_player_round to populate the grid.
  defp load_grid(lv, player, round) do
    lv
    |> form("#by-player-select", player_id: player.id, round_id: round.id)
    |> render_change()
  end

  test "admin enters a player's pick by player, and it persists", %{
    conn: conn,
    round: round,
    player: player
  } do
    f = fixture!(round)
    {:ok, lv, _html} = live(conn, ~p"/admin/predictions?view=player")
    load_grid(lv, player, round)

    lv
    |> form("#by-player-form",
      player_id: player.id,
      round_id: round.id,
      rows: %{"#{f.id}" => %{"home_goals" => "2", "away_goals" => "1"}},
      booster_fixture_id: ""
    )
    |> render_submit()

    [pred] = Predictions.list_player_predictions(player.id)
    assert pred.fixture_id == f.id
    assert pred.home_goals == 2
    assert pred.away_goals == 1
  end

  test "a pick entered by admin shows on the player's /predictions page", %{
    conn: conn,
    round: round,
    player: player
  } do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{team1: "Mexico", team2: "Poland", kickoff_at: future})

    {:ok, lv, _} = live(conn, ~p"/admin/predictions?view=player")
    load_grid(lv, player, round)

    lv
    |> form("#by-player-form",
      player_id: player.id,
      round_id: round.id,
      rows: %{"#{f.id}" => %{"home_goals" => "3", "away_goals" => "0"}},
      booster_fixture_id: "#{f.id}"
    )
    |> render_submit()

    [pred] = Predictions.list_player_predictions(player.id)
    assert pred.booster

    # Now visit the player's own dashboard as that player.
    player_conn = build_conn() |> log_in_player(player)
    {:ok, _lv2, html} = live(player_conn, ~p"/predictions")

    assert html =~ "Mexico"
    assert html =~ "3"
  end

  test "by-fixture view lists every player's pick and flags missing ones", %{
    conn: conn,
    round: round,
    player: player
  } do
    _other = player_fixture(%{display_name: "Sam"})
    f = fixture!(round)

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: f.id,
        home_goals: 1,
        away_goals: 0
      })

    {:ok, lv, _} = live(conn, ~p"/admin/predictions?view=fixture")

    html =
      lv
      |> form("#by-fixture-select", fixture_id: f.id)
      |> render_change()

    assert html =~ "Dave"
    assert html =~ "Sam"
    assert html =~ "no pick"
  end

  test "first-scorer inputs appear only for knockout rounds, not group rounds", %{
    conn: conn,
    round: group_round,
    player: player
  } do
    {:ok, ko_round} =
      Tournament.create_round(%{name: "Round of 16", stage: :knockout, ordinal: 4})

    _g = fixture!(group_round)
    _k = fixture!(ko_round)

    {:ok, lv, _} = live(conn, ~p"/admin/predictions?view=player")

    group_html = load_grid(lv, player, group_round)
    refute group_html =~ "first_scorer_player"
    refute group_html =~ "1st player"

    ko_html = load_grid(lv, player, ko_round)
    assert ko_html =~ "first_scorer_player"
    assert ko_html =~ "1st player"
  end

  test "boosting a blank scoreline flashes the booster-on-blank message and saves nothing", %{
    conn: conn,
    round: round,
    player: player
  } do
    f = fixture!(round)
    {:ok, lv, _html} = live(conn, ~p"/admin/predictions?view=player")
    load_grid(lv, player, round)

    html =
      lv
      |> form("#by-player-form",
        player_id: player.id,
        round_id: round.id,
        rows: %{"#{f.id}" => %{"home_goals" => "", "away_goals" => ""}},
        booster_fixture_id: "#{f.id}"
      )
      |> render_submit()

    # The specific copy from prediction_error/1 — not the generic "Could not save".
    assert html =~ "enter a score for the boosted fixture"
    assert html =~ "Nothing was saved."
    assert Predictions.list_player_predictions(player.id) == []
  end
end
