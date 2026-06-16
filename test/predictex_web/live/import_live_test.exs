defmodule PredictexWeb.ImportLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Predictex.{Predictions, Tournament}

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

  defp paste_json(rows), do: Jason.encode!(rows)

  test "redirects to login when logged out", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/players/log-in"}}} = live(conn, ~p"/import")
  end

  describe "authenticated import" do
    setup :register_and_log_in_player

    test "paste -> preview shows matched picks, then confirm writes them for the member", ctx do
      %{conn: conn, player: player} = ctx
      round = group_round(1)
      fx = fixture!(round, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])
      ])

      {:ok, view, _html} = live(conn, ~p"/import")

      rows = [
        %{"round" => 1, "matchId" => 1, "homeScore" => 2, "awayScore" => 0, "booster" => true}
      ]

      html =
        view
        |> form("#paste-form", paste: %{json: paste_json(rows)})
        |> render_submit()

      assert html =~ "Mexico"
      assert html =~ "South Africa"

      render_click(view, "confirm", %{})

      [pred] = Predictions.list_player_predictions(player.id)
      assert pred.fixture_id == fx.id
      assert pred.home_goals == 2
      assert pred.away_goals == 0
      assert pred.booster == true
    end

    test "import overwrites an existing pick for the same fixture", ctx do
      %{conn: conn, player: player} = ctx
      round = group_round(1)
      fx = fixture!(round, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])

      {:ok, _} =
        Predictions.admin_upsert_prediction(%{
          player_id: player.id,
          fixture_id: fx.id,
          home_goals: 0,
          away_goals: 0,
          booster: false
        })

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])
      ])

      {:ok, view, _} = live(conn, ~p"/import")

      rows = [
        %{"round" => 1, "matchId" => 1, "homeScore" => 3, "awayScore" => 1, "booster" => false}
      ]

      view |> form("#paste-form", paste: %{json: paste_json(rows)}) |> render_submit()
      render_click(view, "confirm", %{})

      [pred] = Predictions.list_player_predictions(player.id)
      assert pred.home_goals == 3
      assert pred.away_goals == 1
    end

    test "unmatched rows render with a reason and do not block matched", ctx do
      %{conn: conn} = ctx
      round = group_round(1)
      _fx = fixture!(round, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])
      ])

      {:ok, view, _} = live(conn, ~p"/import")

      rows = [
        %{"round" => 1, "matchId" => 1, "homeScore" => 2, "awayScore" => 0, "booster" => false},
        %{"round" => 1, "matchId" => 999, "homeScore" => 1, "awayScore" => 1, "booster" => false}
      ]

      html = view |> form("#paste-form", paste: %{json: paste_json(rows)}) |> render_submit()
      assert html =~ "Mexico"
      # matches the unmatched-reason copy (apostrophe may be HTML-escaped)
      assert html =~ "couldn"
    end

    test "booster on an unmatched row shows the warning", ctx do
      %{conn: conn} = ctx
      round = group_round(1)
      _fx = fixture!(round, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])

      stub_rounds([
        fifa_round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])
      ])

      {:ok, view, _} = live(conn, ~p"/import")

      rows = [
        %{"round" => 1, "matchId" => 999, "homeScore" => 2, "awayScore" => 0, "booster" => true}
      ]

      html = view |> form("#paste-form", paste: %{json: paste_json(rows)}) |> render_submit()
      assert html =~ "booster"
    end

    test "malformed paste keeps the awaiting state with an error", ctx do
      %{conn: conn} = ctx
      stub_rounds([])
      {:ok, view, _} = live(conn, ~p"/import")

      html = view |> form("#paste-form", paste: %{json: "not json"}) |> render_submit()
      assert html =~ "could not read"
    end
  end
end
