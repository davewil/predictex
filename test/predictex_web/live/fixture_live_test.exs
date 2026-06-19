defmodule PredictexWeb.FixtureLiveTest do
  # async: false retained pending a separate async-safety review (predictex-uhf follow-up);
  # live_buzz was contracted away (the feature is unconditional), so there is no flag state here.
  use PredictexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.{Predictions, Tournament, Capture}

  defp round! do
    {:ok, r} = Tournament.create_round(%{name: "Final", stage: :knockout, ordinal: 1})
    r
  end

  defp live_fixture!(round) do
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "live-#{System.unique_integer([:positive])}",
        team1: "England",
        team2: "France",
        round_id: round.id,
        kickoff_at: past,
        status: :live,
        is_live: true,
        live_home_goals: 1,
        live_away_goals: 0,
        live_minute: "45'"
      })

    fx
  end

  defp future_fixture!(round) do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "fut-#{System.unique_integer([:positive])}",
        team1: "Spain",
        team2: "Germany",
        round_id: round.id,
        kickoff_at: future
      })

    fx
  end

  test "after kickoff: shows everyone's picks and scenario labels", %{conn: conn} do
    viewer = player_fixture(%{display_name: "Viewer"})
    other = player_fixture(%{display_name: "Zoe"})
    round = round!()
    fx = live_fixture!(round)

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: other.id,
        fixture_id: fx.id,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    assert html =~ "if it ends"
    assert html =~ "Zoe"
  end

  test "before kickoff: picks are hidden (anti-copy)", %{conn: conn} do
    viewer = player_fixture(%{display_name: "Viewer"})
    other = player_fixture(%{display_name: "Zoe"})
    round = round!()
    fx = future_fixture!(round)

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: other.id,
        fixture_id: fx.id,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    refute html =~ "Zoe"
  end

  # handle_info tests — covers lock-flip branch and minute-only branch

  test "lock-flip tick reveals picks without a score change", %{conn: conn} do
    viewer = player_fixture(%{display_name: "Viewer"})
    other = player_fixture(%{display_name: "Zoe"})
    round = round!()
    # Mount on a future fixture (pre-kickoff → picks_visible? false).
    fx = future_fixture!(round)

    # Zoe's prediction is allowed pre-kickoff via create_prediction.
    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: other.id,
        fixture_id: fx.id,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")
    refute html =~ "Zoe"

    # Move kickoff into the past so the next reload sees it as locked.
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    {:ok, _} = Tournament.update_fixture(fx, %{kickoff_at: past})

    # Score unchanged — drives the picks_visible? != now_locked? branch.
    send(lv.pid, {:live_update, fx.id})
    assert render(lv) =~ "Zoe"
  end

  test "minute-only tick advances displayed minute without recomputing scenarios", %{conn: conn} do
    viewer = player_fixture(%{display_name: "Viewer"})
    round = round!()
    # Use a live fixture (already locked, score 1-0, minute "45'").
    fx = live_fixture!(round)

    {:ok, lv, _html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    # Update only the minute — score and is_live unchanged, kickoff in the past so lock stable.
    {:ok, _} = Tournament.update_fixture(fx, %{live_minute: "90"})
    send(lv.pid, {:live_update, fx.id})

    # The minute update hits the else branch (assign fixture only, no projection recompute).
    assert render(lv) =~ "90"
  end

  test "is_live transition tick triggers full recompute and shows LIVE indicator", %{conn: conn} do
    # Drives the `old.is_live != new.is_live` branch in handle_info.
    # Mount on a past-kickoff fixture that is NOT yet live (is_live: false, no live score).
    # The score starts at nil/0, so score_changed? stays false on the transition tick —
    # only the is_live flip triggers load_all. After the update, the LIVE badge renders.
    viewer = player_fixture(%{display_name: "Viewer"})
    round = round!()
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "islive-#{System.unique_integer([:positive])}",
        team1: "Portugal",
        team2: "Morocco",
        round_id: round.id,
        kickoff_at: past,
        status: :live,
        is_live: false
      })

    {:ok, lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")
    refute html =~ "LIVE"

    # Transition: flip is_live true and set a live score (score also changes on the same
    # DB write, which is the realistic production path — LiveScoreSync sets both atomically).
    {:ok, _} =
      Tournament.update_fixture(fx, %{
        is_live: true,
        live_home_goals: 1,
        live_away_goals: 0,
        live_minute: "32'"
      })

    send(lv.pid, {:live_update, fx.id})
    assert render(lv) =~ "LIVE"
  end

  test "settled group fixture shows the final score and per-pick points", %{conn: conn} do
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "recap-1",
        team1: "Egypt",
        team2: "Belgium",
        status: :completed,
        home_goals: 2,
        away_goals: 1,
        kickoff_at: past,
        round_id: round.id
      })

    viewer = player_fixture(%{display_name: "Zoe"})

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: viewer.id,
        fixture_id: fx.id,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    # header score span is present AND shows the correct final score
    assert html =~ ~r/font-score text-4xl font-extrabold[^>]*>.*?2.*?–.*?1/s
    assert html =~ "Zoe"
    # exact prediction earns 30 pts in group stage
    assert html =~ "+30"
  end

  test "settled knockout fixture does NOT show the match recap", %{conn: conn} do
    {:ok, round} =
      Tournament.create_round(%{name: "Quarter-final", stage: :knockout, ordinal: 4})

    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "recap-ko-#{System.unique_integer([:positive])}",
        team1: "Brazil",
        team2: "Argentina",
        status: :completed,
        home_goals: 1,
        away_goals: 0,
        kickoff_at: past,
        round_id: round.id
      })

    viewer = player_fixture(%{display_name: "Ana"})

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: viewer.id,
        fixture_id: fx.id,
        home_goals: 1,
        away_goals: 0
      })

    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    # No header score span (recap? is false for knockout)
    refute html =~ "font-score text-4xl font-extrabold"
    # No per-pick points badge (bg-success/15 is unique to the points badge element)
    refute html =~ "bg-success/15"
  end

  test "score-change tick re-renders updated score", %{conn: conn} do
    viewer = player_fixture(%{display_name: "Viewer"})
    round = round!()
    fx = live_fixture!(round)

    {:ok, lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")
    assert html =~ "1-0"

    {:ok, _} =
      Tournament.update_fixture(fx, %{live_home_goals: 2, live_away_goals: 0, live_minute: "75"})

    send(lv.pid, {:live_update, fx.id})
    assert render(lv) =~ "2-0"
  end

  test "settled group fixture renders a goal breakdown", %{conn: conn} do
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "recap-2",
        team1: "Egypt",
        team2: "Belgium",
        status: :completed,
        home_goals: 1,
        away_goals: 0,
        kickoff_at: past,
        round_id: round.id,
        goals: [%{side: :home, type: :penalty, player: "Salah", minute: "16"}]
      })

    viewer = player_fixture(%{display_name: "Zoe"})
    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    assert html =~ "Salah"
    assert html =~ "16"
    assert html =~ "pen"
  end

  test "settled group fixture renders goals from FIFA snapshot when it reconciles", %{conn: conn} do
    {:ok, round} = Tournament.create_round(%{name: "Matchday 2", stage: :group, ordinal: 2})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "recap-fifa-#{System.unique_integer([:positive])}",
        team1: "Egypt",
        team2: "Belgium",
        status: :completed,
        home_goals: 1,
        away_goals: 1,
        kickoff_at: past,
        round_id: round.id,
        fifa_match_id: "fifa-m99"
      })

    {:ok, _} =
      Capture.record_snapshot(%{
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second),
        endpoint: "detail",
        url: "https://api.fifa.com/m99/detail",
        match_id: "fifa-m99",
        http_status: 200,
        body: %{
          "HomeTeam" => %{
            "Players" => [%{"IdPlayer" => "p1", "PlayerName" => [%{"Description" => "Salah"}]}],
            "Goals" => [%{"IdPlayer" => "p1", "Minute" => "16'", "Type" => 1}]
          },
          "AwayTeam" => %{
            "Players" => [%{"IdPlayer" => "p2", "PlayerName" => [%{"Description" => "Lukaku"}]}],
            "Goals" => [%{"IdPlayer" => "p2", "Minute" => "73'", "Type" => 2}]
          }
        }
      })

    viewer = player_fixture(%{display_name: "Zoe"})
    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    assert html =~ "Lukaku"
  end
end
