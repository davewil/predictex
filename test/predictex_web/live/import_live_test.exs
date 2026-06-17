defmodule PredictexWeb.ImportLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Predictex.{Predictions, Tournament}

  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Safari"
  @desktop "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/120 Safari"

  defp group_round(ordinal) do
    {:ok, r} =
      Tournament.create_round(%{name: "Matchday #{ordinal}", stage: :group, ordinal: ordinal})

    r
  end

  defp fixture!(round, team1, team2, kickoff) do
    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "ref-#{System.unique_integer([:positive])}",
        team1: team1,
        team2: team2,
        status: :scheduled,
        kickoff_at: kickoff,
        round_id: round.id
      })

    f
  end

  defp fifa_round(id, matches), do: %{"id" => id, "stage" => "group", "tournaments" => matches}

  defp fifa_match(id, home, away, date),
    do: %{"id" => id, "homeSquadName" => home, "awaySquadName" => away, "date" => date}

  defp stub_rounds(rounds) do
    prev = Application.get_env(:predictex, :fifa_reference_fun)
    Application.put_env(:predictex, :fifa_reference_fun, fn -> {:ok, rounds} end)
    on_exit(fn -> Application.put_env(:predictex, :fifa_reference_fun, prev) end)
  end

  # The raw FIFA envelope as it appears at /prediction/show/{round} (no round field).
  defp fifa_envelope(preds) do
    Jason.encode!(%{
      "success" => %{
        "predictions" =>
          Enum.map(preds, fn {match_id, hs, as, booster} ->
            %{"matchId" => match_id, "homeScore" => hs, "awayScore" => as, "booster" => booster}
          end)
      },
      "errors" => []
    })
  end

  # Base64url payload as the desktop bookmarklet emits it (round-tagged rows for all rounds).
  defp bookmarklet_payload(rows) do
    rows |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  defp ua(conn, agent), do: Plug.Conn.put_req_header(conn, "user-agent", agent)

  # Visible text only — Floki.text drops attribute values (so the bookmarklet's javascript:
  # href, which legitimately contains "json"/"JSON.stringify", is excluded) and <script> content.
  # The jargon ban is about user-facing copy, not the opaque bookmarklet code.
  defp visible_text(html),
    do: html |> Floki.parse_document!() |> Floki.text() |> String.downcase()

  test "redirects to login when logged out", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/players/log-in"}}} = live(ua(conn, @iphone), ~p"/import")
  end

  describe "mobile per-round import" do
    setup :register_and_log_in_player

    test "paste round 1 -> preview -> confirm writes round 1 and reveals round 2", ctx do
      %{conn: conn, player: player} = ctx
      r1 = group_round(1)
      fx = fixture!(r1, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
      group_round(2)

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")]),
        fifa_round(2, [])
      ])

      {:ok, view, html} = live(ua(conn, @iphone), ~p"/import")
      assert html =~ "Round 1"
      refute html =~ "Round 2"

      html =
        view
        |> form("#paste-form", paste: %{json: fifa_envelope([{1, 2, 0, true}])})
        |> render_submit()

      assert html =~ "Mexico"
      assert html =~ "South Africa"

      html = render_click(view, "confirm_round", %{})

      # Round 1 is written to the DB now (not held in assigns).
      [pred] = Predictions.list_player_predictions(player.id)
      assert pred.fixture_id == fx.id
      assert pred.home_goals == 2 and pred.away_goals == 0 and pred.booster == true

      # And the flow has advanced to round 2.
      assert html =~ "Round 2"
    end

    test "a round is written to the DB the moment it is confirmed (not held until the end)",
         ctx do
      %{conn: conn, player: player} = ctx
      r1 = group_round(1)
      fixture!(r1, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
      group_round(2)

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")]),
        fifa_round(2, [])
      ])

      {:ok, view, _} = live(ua(conn, @iphone), ~p"/import")

      view
      |> form("#paste-form", paste: %{json: fifa_envelope([{1, 3, 1, false}])})
      |> render_submit()

      render_click(view, "confirm_round", %{})

      # Persisted immediately — BEFORE rounds 2/3 are confirmed. A tab discard here (dropping all
      # LiveView assigns) cannot lose it. Regression guard against accumulate-then-confirm.
      [pred] = Predictions.list_player_predictions(player.id)
      assert pred.home_goals == 3 and pred.away_goals == 1
    end

    test "confirming round 2 does not clobber round 1's saved picks", ctx do
      %{conn: conn, player: player} = ctx
      r1 = group_round(1)
      r2 = group_round(2)
      fx1 = fixture!(r1, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
      fx2 = fixture!(r2, "Brazil", "Serbia", ~U[2026-06-18 19:00:00Z])

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")]),
        fifa_round(2, [fifa_match(1, "Brazil", "Serbia", "2026-06-18T20:00:00+01:00")])
      ])

      {:ok, view, _} = live(ua(conn, @iphone), ~p"/import")

      view
      |> form("#paste-form", paste: %{json: fifa_envelope([{1, 2, 0, true}])})
      |> render_submit()

      render_click(view, "confirm_round", %{})

      view
      |> form("#paste-form", paste: %{json: fifa_envelope([{1, 1, 1, false}])})
      |> render_submit()

      render_click(view, "confirm_round", %{})

      preds = Map.new(Predictions.list_player_predictions(player.id), &{&1.fixture_id, &1})
      assert preds[fx1.id].home_goals == 2 and preds[fx1.id].booster == true
      assert preds[fx2.id].home_goals == 1
    end

    test "a round with nothing matchable can be skipped without writing", ctx do
      %{conn: conn, player: player} = ctx
      group_round(1)
      group_round(2)
      stub_rounds([fifa_round(1, []), fifa_round(2, [])])

      {:ok, view, _} = live(ua(conn, @iphone), ~p"/import")

      html =
        view
        |> form("#paste-form", paste: %{json: fifa_envelope([{99, 2, 0, false}])})
        |> render_submit()

      assert html =~ "continue" or html =~ "Continue"
      html = render_click(view, "skip_round", %{})

      assert Predictions.list_player_predictions(player.id) == []
      assert html =~ "Round 2"
    end

    test "malformed paste keeps the round with a friendly error", ctx do
      %{conn: conn} = ctx
      group_round(1)
      stub_rounds([fifa_round(1, [])])
      {:ok, view, _} = live(ua(conn, @iphone), ~p"/import")

      html = view |> form("#paste-form", paste: %{json: "not json"}) |> render_submit()
      assert html =~ "couldn"
    end

    test "no developer jargon appears on the mobile flow", ctx do
      %{conn: conn} = ctx
      group_round(1)
      stub_rounds([fifa_round(1, [])])
      {:ok, _view, html} = live(ua(conn, @iphone), ~p"/import")
      text = visible_text(html)
      refute text =~ "bookmarklet"
      refute text =~ "json"
      refute text =~ "console"
    end

    test "the paste box placeholder interpolates the round number (no raw template leak)", ctx do
      %{conn: conn} = ctx
      group_round(1)
      stub_rounds([fifa_round(1, [])])
      {:ok, _view, html} = live(ua(conn, @iphone), ~p"/import")
      assert html =~ "Paste your Round 1 picks here"
      refute html =~ "{@round}"
    end
  end

  describe "desktop bookmarklet import" do
    setup :register_and_log_in_player

    test "bookmarklet payload -> preview all -> confirm writes every round", ctx do
      %{conn: conn, player: player} = ctx
      r1 = group_round(1)
      r2 = group_round(2)
      fx1 = fixture!(r1, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
      fx2 = fixture!(r2, "Brazil", "Serbia", ~U[2026-06-18 19:00:00Z])

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")]),
        fifa_round(2, [fifa_match(1, "Brazil", "Serbia", "2026-06-18T20:00:00+01:00")])
      ])

      {:ok, view, html} = live(ua(conn, @desktop), ~p"/import")
      assert html =~ "Import my picks"

      rows = [
        %{"round" => 1, "matchId" => 1, "homeScore" => 2, "awayScore" => 0, "booster" => true},
        %{"round" => 2, "matchId" => 1, "homeScore" => 1, "awayScore" => 1, "booster" => false}
      ]

      html = render_hook(view, "payload", %{"data" => bookmarklet_payload(rows)})
      assert html =~ "Mexico"
      assert html =~ "Brazil"

      render_click(view, "confirm", %{})

      preds = Map.new(Predictions.list_player_predictions(player.id), &{&1.fixture_id, &1})
      assert preds[fx1.id].home_goals == 2
      assert preds[fx2.id].home_goals == 1
    end

    test "no developer jargon and no console-fallback copy on desktop", ctx do
      %{conn: conn} = ctx
      stub_rounds([])
      {:ok, _view, html} = live(ua(conn, @desktop), ~p"/import")
      text = visible_text(html)
      refute text =~ "bookmarklet"
      refute text =~ "json"
      refute text =~ "console"
    end
  end
end
