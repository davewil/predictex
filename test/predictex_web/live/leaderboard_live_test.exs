defmodule PredictexWeb.LeaderboardLiveTest do
  # Runs async: this view mutates no global state (live_buzz was contracted away), and it
  # never touches the supervised Replay.Cache, so isolated-sandbox mode is safe (predictex-dmh).
  use PredictexWeb.ConnCase, async: true

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

  test "toggles between the overall and knockout boards", %{conn: conn} do
    {:ok, group} =
      Predictex.Tournament.create_round(%{name: "Group 1", stage: :group, ordinal: 1})

    {:ok, ko} =
      Predictex.Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})

    # Two group fixtures to build up overall score for GroupOnly
    {:ok, gfx1} =
      Predictex.Tournament.create_fixture(%{
        external_ref: "g1",
        team1: "A",
        team2: "B",
        round_id: group.id,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })

    {:ok, gfx2} =
      Predictex.Tournament.create_fixture(%{
        external_ref: "g2",
        team1: "C",
        team2: "D",
        round_id: group.id,
        status: :completed,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, kfx} =
      Predictex.Tournament.create_fixture(%{
        external_ref: "k",
        team1: "E",
        team2: "F",
        round_id: ko.id,
        status: :completed,
        home_goals: 2,
        away_goals: 1
      })

    gonly = player_fixture(%{display_name: "GroupOnly"})
    both = player_fixture(%{display_name: "BothRounds"})

    # GroupOnly scores both group fixtures exactly (60 overall points)
    {:ok, _} =
      Predictex.Predictions.create_prediction(%{
        player_id: gonly.id,
        fixture_id: gfx1.id,
        home_goals: 1,
        away_goals: 0
      })

    {:ok, _} =
      Predictex.Predictions.create_prediction(%{
        player_id: gonly.id,
        fixture_id: gfx2.id,
        home_goals: 2,
        away_goals: 1
      })

    # BothRounds scores the knockout fixture exactly (30 knockout points only)
    {:ok, _} =
      Predictex.Predictions.admin_upsert_prediction(%{
        player_id: both.id,
        fixture_id: kfx.id,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, lv, html} = live(conn, ~p"/")
    # Overall board: GroupOnly is the league leader (highest overall score)
    assert html =~ "League leader"
    assert html =~ "GroupOnly"

    # Switch to knockout: BothRounds is now the league leader (only player with knockout points)
    html = lv |> element("button", "Knockout") |> render_click()
    assert html =~ "League leader"
    assert html =~ "BothRounds"
  end

  describe "current player highlight (predictex-kzz)" do
    setup do
      {:ok, round} = Tournament.create_round(%{name: "Round 1", stage: :group, ordinal: 1})

      {:ok, f1} =
        Tournament.create_fixture(%{
          external_ref: "kzz-1",
          team1: "Egypt",
          team2: "Belgium",
          status: :completed,
          home_goals: 1,
          away_goals: 2,
          round_id: round.id
        })

      {:ok, f2} =
        Tournament.create_fixture(%{
          external_ref: "kzz-2",
          team1: "Spain",
          team2: "Japan",
          status: :completed,
          home_goals: 0,
          away_goals: 0,
          round_id: round.id
        })

      alice = player_fixture(%{display_name: "Alice"})
      bob = player_fixture(%{display_name: "Bob"})

      # Alice scores both fixtures exact (champion); Bob only the first, so Bob sits
      # strictly below Alice in the chasing pack regardless of exact point values.
      for {p, fx} <- [{alice, f1}, {alice, f2}, {bob, f1}] do
        {:ok, _} =
          Predictions.create_prediction(%{
            player_id: p.id,
            fixture_id: fx.id,
            home_goals: fx.home_goals,
            away_goals: fx.away_goals
          })
      end

      %{alice: alice, bob: bob}
    end

    test "shows no YOU badge for a logged-out visitor", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")
      assert html =~ "Alice"
      assert html =~ "Bob"
      refute html =~ "YOU"
    end

    test "marks the logged-in player's own row in the chasing pack", %{conn: conn, bob: bob} do
      {:ok, _lv, html} = live(log_in_player(conn, bob), ~p"/")
      assert html =~ "YOU"
    end

    test "marks the logged-in player when they are the champion (hero)", %{
      conn: conn,
      alice: alice
    } do
      {:ok, _lv, html} = live(log_in_player(conn, alice), ~p"/")
      assert html =~ "League leader"
      assert html =~ "YOU"
    end
  end
end
