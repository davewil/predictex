defmodule PredictexWeb.FixtureLiveTest do
  # async: false because the live_buzz flag test mutates global FunWithFlags state (ETS)
  # and would race with other async tests.
  use PredictexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Predictex.AccountsFixtures
  alias Predictex.{Predictions, Tournament}

  defp round!() do
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

  setup do
    on_exit(fn -> FunWithFlags.disable(:live_buzz) end)
    :ok
  end

  test "flag off redirects to home", %{conn: conn} do
    FunWithFlags.disable(:live_buzz)
    player = player_fixture(%{display_name: "Viewer"})
    round = round!()
    fx = live_fixture!(round)

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in_player(player) |> live(~p"/fixtures/#{fx.id}")
  end

  test "flag on, after kickoff: shows everyone's picks and scenario labels", %{conn: conn} do
    FunWithFlags.enable(:live_buzz)
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

  test "flag on, before kickoff: picks are hidden (anti-copy)", %{conn: conn} do
    FunWithFlags.enable(:live_buzz)
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
    FunWithFlags.enable(:live_buzz)
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
    FunWithFlags.enable(:live_buzz)
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

  test "score-change tick re-renders updated score", %{conn: conn} do
    FunWithFlags.enable(:live_buzz)
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
end
