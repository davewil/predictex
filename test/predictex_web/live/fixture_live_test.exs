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

  # A settled GROUP fixture (so recap? is true → Gap A has teeth) with a fifa_match_id.
  defp settled_group_fixture!(opts) do
    {:ok, round} =
      Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})

    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    {:ok, fx} =
      Tournament.create_fixture(%{
        external_ref: "replay-#{System.unique_integer([:positive])}",
        team1: "Egypt",
        team2: "Belgium",
        status: :completed,
        home_goals: 2,
        away_goals: 1,
        kickoff_at: past,
        round_id: round.id,
        fifa_match_id: Keyword.get(opts, :fifa_match_id)
      })

    fx
  end

  # Records the brief's capture timeline (10' 0-0, 30' 1-0, 80' 2-1, 85' 2-1 — the
  # last a minute-only frame that doesn't change the score) for `match_id`.
  defp record_timeline!(match_id) do
    timeline = [
      {"10'", 0, 0},
      {"30'", 1, 0},
      {"80'", 2, 1},
      {"85'", 2, 1}
    ]

    base = DateTime.utc_now() |> DateTime.truncate(:second)

    timeline
    |> Enum.with_index()
    |> Enum.each(fn {{minute, h, a}, i} ->
      {:ok, _} =
        Capture.record_snapshot(%{
          captured_at: DateTime.add(base, i, :second),
          endpoint: "detail",
          url: "https://api.fifa.com/#{match_id}/detail",
          match_id: match_id,
          http_status: 200,
          body: %{
            "MatchStatus" => 3,
            "MatchTime" => minute,
            "HomeTeam" => %{"Score" => h},
            "AwayTeam" => %{"Score" => a}
          }
        })
    end)
  end

  # Flag off everywhere except the replay describe; proves no leak onto the cache path.
  test "replay control is hidden when the flag is off", %{conn: conn} do
    assert FunWithFlags.enabled?(:match_replay) == false

    fx = settled_group_fixture!(fifa_match_id: "replay-flagoff")
    record_timeline!(fx.fifa_match_id)
    viewer = player_fixture(%{display_name: "Zoe"})

    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    refute html =~ "Replay this match"
  end

  describe "replay mode" do
    setup do
      start_supervised!(Predictex.Replay.Cache)
      # The FunWithFlags cache is disabled in test (config/test.exs), so this enable writes
      # only to the sandboxed Ecto store and is rolled back at test end — no on_exit teardown
      # is needed (and a DB-write teardown would crash: on_exit runs after the sandbox owner
      # dies). The separate top-level "flag off" test proves the flag does not leak here.
      FunWithFlags.enable(:match_replay)
      :ok
    end

    test "flag isolation smoke: flag is enabled inside the describe" do
      assert FunWithFlags.enabled?(:match_replay) == true
    end

    test "replay shows live buzz and hides the recap (Gap A)", %{conn: conn} do
      fx = settled_group_fixture!(fifa_match_id: "replay-gapa")
      record_timeline!(fx.fifa_match_id)
      viewer = player_fixture(%{display_name: "Zoe"})

      {:ok, _} =
        Predictions.admin_upsert_prediction(%{
          player_id: viewer.id,
          fixture_id: fx.id,
          home_goals: 2,
          away_goals: 1
        })

      {:ok, lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

      # Pre-replay: the recap is showing and the control is offered.
      assert html =~ "Goals"
      assert html =~ "Replay this match"

      # Start → frame 0 (10' 0-0): LIVE, frame-0 minute, and NO recap "Goals".
      html = render_click(lv, "start_replay")
      assert html =~ "LIVE"
      assert html =~ "10&#39;"
      refute html =~ "Goals"

      # Tick to the terminal frame (4 frames → 3 ticks after the initial advance).
      send(lv.pid, :replay_tick)
      send(lv.pid, :replay_tick)
      html = render(send(lv.pid, :replay_tick) && lv)

      # Terminal-stay: final frame (85') remains displayed; controls show Restart/Stop.
      assert html =~ "85&#39;"
      assert html =~ "Restart"
      assert html =~ "Stop"
    end

    test "minute-only frame advances the minute without changing the score (Gap B#1)", %{
      conn: conn
    } do
      fx = settled_group_fixture!(fifa_match_id: "replay-gapb")
      record_timeline!(fx.fifa_match_id)
      viewer = player_fixture(%{display_name: "Zoe"})

      {:ok, lv, _html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

      render_click(lv, "start_replay")
      # Advance through 30' 1-0, 80' 2-1, then 85' 2-1 (minute-only).
      send(lv.pid, :replay_tick)
      send(lv.pid, :replay_tick)
      html = render(send(lv.pid, :replay_tick) && lv)

      # The 85' minute is shown, and the score is still 2-1 (no recompute branch).
      assert html =~ "85&#39;"
      assert html =~ ~r/2.*?–.*?1/s
    end

    test "replay performs no DB write to the fixture", %{conn: conn} do
      fx = settled_group_fixture!(fifa_match_id: "replay-nowrite")
      record_timeline!(fx.fifa_match_id)
      viewer = player_fixture(%{display_name: "Zoe"})

      {:ok, lv, _html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

      render_click(lv, "start_replay")
      send(lv.pid, :replay_tick)

      reloaded = Tournament.get_fixture!(fx.id, :round)
      assert reloaded.status == :completed
      assert reloaded.is_live == false
      assert reloaded.live_home_goals == nil
      assert {reloaded.home_goals, reloaded.away_goals} == {2, 1}
    end

    test "no replay control for a completed fixture without a capture timeline", %{conn: conn} do
      fx = settled_group_fixture!(fifa_match_id: "replay-notimeline")
      # No record_timeline! — fifa_match_id present but zero captures.
      viewer = player_fixture(%{display_name: "Zoe"})

      {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

      refute html =~ "Replay this match"
    end
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

  test "after kickoff on a knockout fixture: reveals first-team and first-scorer picks", %{
    conn: conn
  } do
    viewer = player_fixture(%{display_name: "Viewer"})
    other = player_fixture(%{display_name: "Zoe"})
    round = round!()
    fx = live_fixture!(round)

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: other.id,
        fixture_id: fx.id,
        home_goals: 2,
        away_goals: 1,
        first_scorer_side: :home,
        first_scorer_player: "Mbappe"
      })

    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    # home side maps to team1 (England), same orientation the goals section uses.
    assert html =~ "First to score: England · Mbappe"
  end

  test "knockout pick with no first-team entered renders a dash, not the away team", %{conn: conn} do
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
        # no first_scorer_side / first_scorer_player
      })

    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    assert html =~ "First to score: — · —"
    # The nil→team2 idiom trap: a blank first-team must NOT show the away team.
    refute html =~ "First to score: France"
  end

  test "group-stage picks reveal omits the first-team/first-scorer line", %{conn: conn} do
    viewer = player_fixture(%{display_name: "Viewer"})
    other = player_fixture(%{display_name: "Zoe"})
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    fx = live_fixture!(round)

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: other.id,
        fixture_id: fx.id,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, _lv, html} = conn |> log_in_player(viewer) |> live(~p"/fixtures/#{fx.id}")

    assert html =~ "Zoe"
    refute html =~ "First to score:"
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
    assert html =~ "16&#39;"
    refute html =~ "16&#39;&#39;"
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
    assert html =~ "73&#39;"
    refute html =~ "73&#39;&#39;"
  end
end
