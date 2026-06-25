defmodule PredictexWeb.MyPredictionsLiveTest do
  # Runs async: this view mutates no global state (live_buzz was contracted away), and it
  # never touches the supervised Replay.Cache, so isolated-sandbox mode is safe (predictex-dmh).
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.{Predictions, Tournament}

  defp fixture!(round, attrs) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      team1: "Mexico",
      team2: "Poland",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  setup do
    {:ok, round} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    %{round: round}
  end

  # Tests tagged :native_ko exercise the editable knockout form, which is gated behind the
  # :native_ko_entry FunWithFlags flag (predictex-5q6). Enable it for those; the DB write
  # rolls back with the sandbox txn and the ETS cache is flushed in on_exit so the enabled
  # state can't leak into later tests (the compile-env-safe isolation — see config/test.exs).
  setup tags do
    if tags[:native_ko] do
      FunWithFlags.enable(:native_ko_entry)
      on_exit(fn -> FunWithFlags.Store.Cache.flush() end)
    end

    :ok
  end

  test "redirects to login when logged out", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/players/log-in"}}} = live(conn, ~p"/predictions")
  end

  test "shows the member's pick, points and a no-pick warning", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "Dave"})

    before_kickoff =
      DateTime.utc_now() |> DateTime.add(-3601, :second) |> DateTime.truncate(:second)

    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    done = fixture!(round, %{kickoff_at: past, status: :completed, home_goals: 2, away_goals: 1})
    _open = fixture!(round, %{team1: "Brazil", team2: "Serbia", kickoff_at: future})

    {:ok, _} =
      Predictions.create_prediction(
        %{player_id: player.id, fixture_id: done.id, home_goals: 2, away_goals: 1},
        before_kickoff
      )

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    assert html =~ "My Predictions"
    assert html =~ "Mexico"
    assert html =~ "No pick imported"

    # points breakdown labels regular-scoring points as "from fixtures", not a fixture count
    # (predictex-d64 — same mislabel as the leaderboard champion card).
    assert html =~ "from fixtures"
    refute html =~ ~r/\d fixtures ·/
  end

  test "a member sees their own picks, not another player's", %{conn: conn, round: round} do
    me = player_fixture(%{display_name: "Me"})
    them = player_fixture(%{display_name: "Them"})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{kickoff_at: future})

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: them.id,
        fixture_id: f.id,
        home_goals: 4,
        away_goals: 4
      })

    {:ok, _lv, html} = conn |> log_in_player(me) |> live(~p"/predictions")
    refute html =~ "4 – 4"
  end

  test "switching round tabs shows that round's fixtures", %{conn: conn, round: round} do
    {:ok, round2} = Tournament.create_round(%{name: "Matchday 2", stage: :group, ordinal: 2})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    _f1 = fixture!(round, %{kickoff_at: future})
    _f2 = fixture!(round2, %{team1: "Japan", team2: "Germany", kickoff_at: future})
    player = player_fixture(%{display_name: "Dave"})

    {:ok, lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")
    refute html =~ "Japan"

    html = lv |> element("button", "Matchday 2") |> render_click()
    assert html =~ "Japan"
  end

  test "shows the live score on the card for a live fixture", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "LiveTester"})
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    live_fx =
      fixture!(round, %{
        kickoff_at: past,
        status: :live,
        is_live: true,
        live_home_goals: 1,
        live_away_goals: 0,
        live_minute: "23'"
      })

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: live_fx.id,
        home_goals: 1,
        away_goals: 0
      })

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")
    assert html =~ "LIVE"
    assert html =~ "1-0"
  end

  test "live badge links to the fixture drill-down for a live fixture",
       %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "CTATester"})
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    live_fx =
      fixture!(round, %{
        kickoff_at: past,
        status: :live,
        is_live: true,
        live_home_goals: 2,
        live_away_goals: 1,
        live_minute: "67'"
      })

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: live_fx.id,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    assert html =~ ~s(href="/fixtures/#{live_fx.id}")
  end

  test "no CTA more than 30 minutes before kickoff", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "NotLiveTester"})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    _fx = fixture!(round, %{kickoff_at: future, is_live: false})

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    refute html =~ ~s(href="/fixtures/)
  end

  test "CTA opens 30 min before kickoff with a 'Match preview' label",
       %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "PreviewTester"})
    soon = DateTime.utc_now() |> DateTime.add(20 * 60, :second) |> DateTime.truncate(:second)
    fx = fixture!(round, %{kickoff_at: soon, is_live: false})

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    assert html =~ ~s(href="/fixtures/#{fx.id}")
    assert html =~ "Match preview"
  end

  test "CTA stays after full-time as a 'Match recap' link", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "RecapTester"})
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    fx = fixture!(round, %{kickoff_at: past, status: :completed, home_goals: 2, away_goals: 1})

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    assert html =~ ~s(href="/fixtures/#{fx.id}")
    assert html =~ "Match recap"
  end

  test "shows a 'Next match' countdown banner for the soonest upcoming fixture",
       %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "CountdownTester"})

    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    soon = DateTime.utc_now() |> DateTime.add(2 * 3600, :second) |> DateTime.truncate(:second)

    _done =
      fixture!(round, %{
        team1: "Old",
        team2: "Done",
        kickoff_at: past,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })

    _next = fixture!(round, %{team1: "England", team2: "Croatia", kickoff_at: soon})

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    assert html =~ "Next match"
    assert html =~ "England"
    assert html =~ "Croatia"
    # the colocated countdown hook is fed the kickoff timestamp to tick against
    assert html =~ ~s(data-kickoff="#{DateTime.to_iso8601(soon)}")
  end

  test "no 'Next match' banner when nothing is upcoming", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "NoNextTester"})
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    _done =
      fixture!(round, %{kickoff_at: past, status: :completed, home_goals: 0, away_goals: 0})

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    refute html =~ "Next match"
  end

  test "a :tick re-pulls and re-renders the dashboard without a page reload",
       %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "Ticker"})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    fx = fixture!(round, %{team1: "Spain", team2: "Japan", kickoff_at: future})

    {:ok, _} =
      Predictions.admin_upsert_prediction(%{
        player_id: player.id,
        fixture_id: fx.id,
        home_goals: 0,
        away_goals: 0
      })

    {:ok, lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")
    refute html =~ "LIVE"

    # the match goes live in the DB after mount …
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    fx
    |> Ecto.Changeset.change(%{
      kickoff_at: past,
      status: :live,
      is_live: true,
      live_home_goals: 2,
      live_away_goals: 1,
      live_minute: "67'"
    })
    |> Predictex.Repo.update!()

    # … and the next tick reflects it over the socket, no remount
    send(lv.pid, :tick)
    rendered = render(lv)

    assert rendered =~ "LIVE"
    assert rendered =~ "2-1"
  end

  test "a fixtures-changed broadcast re-pulls and re-renders the dashboard, no poll (predictex-9p0)",
       %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "Subscriber"})
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    # already kicked off (so the clock-tick is idle — only PubSub can move this dashboard)
    fx = fixture!(round, %{team1: "Spain", team2: "Japan", kickoff_at: past, status: :scheduled})

    {:ok, lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")
    refute html =~ "LIVE"

    fx
    |> Ecto.Changeset.change(%{
      status: :live,
      is_live: true,
      live_home_goals: 2,
      live_away_goals: 1,
      live_minute: "67'"
    })
    |> Predictex.Repo.update!()

    Tournament.broadcast_change()
    rendered = render(lv)

    assert rendered =~ "LIVE"
    assert rendered =~ "2-1"
  end

  # --- knockout native entry (predictex knockout-game Phase 1, Task 4) ---

  @tag :native_ko
  test "member enters native knockout picks via the editable form", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "KoPlayer"})

    # The setup block gives us a group round at ordinal 1 with no fixtures — it is
    # incomplete (no fixtures) and will be the dashboard's active round by default.
    # We need round_open? to return true for our knockout round (ordinal 4), which
    # requires a completed predecessor at ordinal 3. We also close out ordinal 1 by
    # adding a completed fixture so it does not compete as the active round.
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    # Complete the setup round (ordinal 1) so it doesn't steal "active".
    _done1 =
      fixture!(round, %{
        team1: "France",
        team2: "Spain",
        kickoff_at: past,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })

    # Predecessor of knockout round: ordinal 3, group stage, with a completed fixture.
    {:ok, pred_round} =
      Tournament.create_round(%{name: "Matchday 3", stage: :group, ordinal: 3})

    _done3 =
      fixture!(pred_round, %{
        team1: "Brazil",
        team2: "Argentina",
        kickoff_at: past,
        status: :completed,
        home_goals: 2,
        away_goals: 1
      })

    # Knockout round at ordinal 4 (predecessor = ordinal 3, now complete → round_open? true).
    {:ok, ko_round} =
      Tournament.create_round(%{name: "Round of 16", stage: :knockout, ordinal: 4})

    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    ko_fx =
      fixture!(ko_round, %{
        team1: "England",
        team2: "Germany",
        kickoff_at: future
      })

    {:ok, lv, _html} = conn |> log_in_player(player) |> live(~p"/predictions")

    # Click the knockout round chip so it becomes the active round.
    html = lv |> element("button", "Round of 16") |> render_click()

    # The editable form should render for the open knockout round.
    assert html =~ ~s(id="round-entry-4")
    assert html =~ "England"
    assert html =~ "Germany"

    # Submit scoreline + first_scorer_side picks via the form.
    html =
      lv
      |> form("#round-entry-4", %{
        "picks" => %{
          "#{ko_fx.id}" => %{
            "home_goals" => "2",
            "away_goals" => "1",
            "first_scorer_side" => "home"
          }
        },
        "booster_fixture_id" => "#{ko_fx.id}"
      })
      |> render_submit()

    assert html =~ "Saved"

    # Verify the prediction was written to the database.
    pred = Predictions.get_player_fixture_prediction(player.id, ko_fx.id)
    assert pred.home_goals == 2
    assert pred.away_goals == 1
    assert pred.first_scorer_side == :home
    assert pred.booster == true
  end

  test "flag off: an OPEN knockout round stays read-only (native form dark-shipped)", %{
    conn: conn,
    round: round
  } do
    # predictex-5q6 dark-ship gate: even with the knockout round fully open (predecessor
    # complete → round_open? true), the editable native form must NOT render while the
    # :native_ko_entry flag is off (this test is deliberately UNtagged → flag off). Members
    # see the read-only FIFA-import grid until the flag is enabled for them.
    player = player_fixture(%{display_name: "FlagOff"})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    # Close the setup round (ordinal 1) so it doesn't steal "active".
    _done1 =
      fixture!(round, %{
        team1: "France",
        team2: "Spain",
        kickoff_at: past,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })

    # Predecessor (ordinal 3) complete → the knockout round at ordinal 4 IS open.
    {:ok, pred_round} =
      Tournament.create_round(%{name: "Matchday 3", stage: :group, ordinal: 3})

    _done3 =
      fixture!(pred_round, %{
        team1: "Brazil",
        team2: "Argentina",
        kickoff_at: past,
        status: :completed,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, ko_round} =
      Tournament.create_round(%{name: "Round of 16", stage: :knockout, ordinal: 4})

    _ko_fx = fixture!(ko_round, %{team1: "England", team2: "Germany", kickoff_at: future})

    {:ok, lv, _html} = conn |> log_in_player(player) |> live(~p"/predictions")
    html = lv |> element("button", "Round of 16") |> render_click()

    # Open round, but flag off → no editable form; the read-only grid (teams) renders instead.
    refute html =~ ~s(id="round-entry-4")
    assert html =~ "England"
    assert html =~ "Germany"
  end

  @tag :native_ko
  test "knockout round flips read-only → editable the moment its predecessor completes (28 Jun cutover)",
       %{conn: conn, round: round} do
    # The real 28-Jun cutover, proven in CI instead of eyeballed live: a knockout round is
    # closed (read-only FIFA-import grid) while the group stage is mid-flight, and flips to the
    # editable native form the instant the last group fixture settles. This is the transition
    # the other KO tests skip — they start from an already-open round.
    player = player_fixture(%{display_name: "Cutover"})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    # Close the setup round (ordinal 1) so it doesn't steal "active".
    _done1 =
      fixture!(round, %{
        team1: "France",
        team2: "Spain",
        kickoff_at: past,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })

    # Predecessor (ordinal 3) starts INCOMPLETE — one still-scheduled fixture. This mirrors
    # the world before 28 Jun: the group stage is unfinished, so R32 is correctly closed.
    {:ok, pred_round} =
      Tournament.create_round(%{name: "Matchday 3", stage: :group, ordinal: 3})

    pred_fx =
      fixture!(pred_round, %{
        team1: "Brazil",
        team2: "Argentina",
        kickoff_at: future,
        status: :scheduled
      })

    # Knockout round (ordinal 4): round_open? iff ordinal 3 is complete.
    {:ok, ko_round} =
      Tournament.create_round(%{name: "Round of 16", stage: :knockout, ordinal: 4})

    ko_fx =
      fixture!(ko_round, %{team1: "England", team2: "Germany", kickoff_at: future})

    {:ok, lv, _html} = conn |> log_in_player(player) |> live(~p"/predictions")

    # Before the predecessor completes: the knockout round is closed → read-only grid, no
    # native entry form. (This is the expected 2026-06-23 screenshot state, by design.)
    html = lv |> element("button", "Round of 16") |> render_click()
    refute html =~ ~s(id="round-entry-4")
    assert html =~ "England"
    assert html =~ "Germany"

    # The last group fixture settles — exactly what Workers.ResultSync does as the group
    # stage ends — and broadcasts the change (same call ResultSync makes post-commit).
    pred_fx
    |> Ecto.Changeset.change(%{status: :completed, home_goals: 2, away_goals: 1})
    |> Predictex.Repo.update!()

    Tournament.broadcast_change()
    html = render(lv)

    # The same knockout round now renders the editable native entry form — the gate flipped
    # open over the live socket, no remount.
    assert html =~ ~s(id="round-entry-4")
    assert html =~ "England"
    assert html =~ "Germany"

    # …and a save through the newly-opened form persists, so the cutover is fully usable.
    html =
      lv
      |> form("#round-entry-4", %{
        "picks" => %{
          "#{ko_fx.id}" => %{
            "home_goals" => "3",
            "away_goals" => "0",
            "first_scorer_side" => "home"
          }
        },
        "booster_fixture_id" => "#{ko_fx.id}"
      })
      |> render_submit()

    assert html =~ "Saved"

    pred = Predictions.get_player_fixture_prediction(player.id, ko_fx.id)
    assert pred.home_goals == 3
    assert pred.away_goals == 0
    assert pred.first_scorer_side == :home
    assert pred.booster == true
  end

  @tag :native_ko
  test "booster on blank-score fixture shows error flash and saves nothing", %{
    conn: conn,
    round: round
  } do
    player = player_fixture(%{display_name: "BoosterBlank"})
    past = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

    # Complete the setup round (ordinal 1) so it doesn't steal "active".
    _done1 =
      fixture!(round, %{
        team1: "France",
        team2: "Spain",
        kickoff_at: past,
        status: :completed,
        home_goals: 1,
        away_goals: 0
      })

    # Predecessor knockout round needs a completed fixture so round_open? returns true.
    {:ok, pred_round} =
      Tournament.create_round(%{name: "Matchday 3", stage: :group, ordinal: 3})

    _done3 =
      fixture!(pred_round, %{
        team1: "Brazil",
        team2: "Argentina",
        kickoff_at: past,
        status: :completed,
        home_goals: 2,
        away_goals: 1
      })

    {:ok, ko_round} =
      Tournament.create_round(%{name: "Round of 16", stage: :knockout, ordinal: 4})

    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    ko_fx =
      fixture!(ko_round, %{
        team1: "England",
        team2: "Germany",
        kickoff_at: future
      })

    {:ok, lv, _html} = conn |> log_in_player(player) |> live(~p"/predictions")
    lv |> element("button", "Round of 16") |> render_click()

    # Submit the form: booster set to ko_fx but home/away goals left blank.
    html =
      lv
      |> form("#round-entry-4", %{
        "picks" => %{
          "#{ko_fx.id}" => %{
            "home_goals" => "",
            "away_goals" => "",
            "first_scorer_side" => ""
          }
        },
        "booster_fixture_id" => "#{ko_fx.id}"
      })
      |> render_submit()

    # Error flash shown — nothing was saved.
    assert html =~ "Can&#39;t boost a fixture with no scoreline"

    # No prediction was written to the database.
    pred = Predictions.get_player_fixture_prediction(player.id, ko_fx.id)
    assert is_nil(pred) or pred.booster == false
  end

  test "locked group rounds remain read-only — no entry form", %{conn: conn, round: round} do
    player = player_fixture(%{display_name: "ReadOnly"})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    _fx = fixture!(round, %{team1: "Italy", team2: "Japan", kickoff_at: future})

    {:ok, _lv, html} = conn |> log_in_player(player) |> live(~p"/predictions")

    # Group rounds are editable only via the import/admin flow, not the native KO form.
    # The active round is ordinal 1 (group), so the read-only fixture grid shows, not a form.
    refute html =~ ~s(id="round-entry-1")
    assert html =~ "Italy"
    assert html =~ "Japan"
  end
end
