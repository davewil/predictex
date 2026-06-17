defmodule Predictex.DemoTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Accounts, Demo, Predictions, Standings, Tournament}
  import Predictex.AccountsFixtures

  # Seed/setup: a completed round with 3 finished fixtures + one live fixture,
  # mimicking the prod state (World Cup fixtures already imported).
  setup do
    {:ok, r1} = Tournament.create_round(%{name: "Group Stage", stage: :group, ordinal: 1})
    {:ok, r2} = Tournament.create_round(%{name: "Group Stage 2", stage: :group, ordinal: 2})

    {:ok, f1} =
      Tournament.create_fixture(%{
        external_ref: "demo-f1",
        team1: "Portugal",
        team2: "Ghana",
        status: :completed,
        home_goals: 3,
        away_goals: 2,
        round_id: r1.id
      })

    {:ok, f2} =
      Tournament.create_fixture(%{
        external_ref: "demo-f2",
        team1: "Brazil",
        team2: "Serbia",
        status: :completed,
        home_goals: 2,
        away_goals: 0,
        round_id: r1.id
      })

    {:ok, f3} =
      Tournament.create_fixture(%{
        external_ref: "demo-f3",
        team1: "France",
        team2: "Australia",
        status: :completed,
        home_goals: 4,
        away_goals: 1,
        round_id: r1.id
      })

    {:ok, live_f} =
      Tournament.create_fixture(%{
        external_ref: "demo-live",
        team1: "Portugal",
        team2: "DR Congo",
        status: :live,
        round_id: r2.id
      })

    %{r1: r1, r2: r2, f1: f1, f2: f2, f3: f3, live_f: live_f}
  end

  describe "seed/0" do
    test "creates 6 demo players with predictions and returns counts" do
      {players_created, predictions_created} = Demo.seed()

      assert players_created == 6
      # 6 players × 4 fixtures
      assert predictions_created == 24
    end

    test "all demo players are confirmed accounts" do
      Demo.seed()

      demo_emails = for name <- ~w[sav dave mia tom priya leo], do: "#{name}@demo.predictex.local"

      for email <- demo_emails do
        player = Accounts.get_player_by_email(email)
        assert player != nil, "Expected demo player #{email} to exist"
        assert player.confirmed_at != nil, "Expected demo player #{email} to be confirmed"
      end
    end

    test "produces a multi-row leaderboard with varied totals from completed fixtures" do
      Demo.seed()

      leaderboard = Standings.leaderboard()

      # All 6 demo players appear
      assert length(leaderboard) == 6

      # At least 3 distinct totals (deliberate scoring ladder ensures this)
      distinct_totals = leaderboard |> Enum.map(& &1.total) |> Enum.uniq()
      assert length(distinct_totals) >= 3
    end

    test "is idempotent: re-running seed returns 0 players and no error" do
      {6, _} = Demo.seed()

      # Second call: all players exist already, so 0 new
      {players_created, _} = Demo.seed()
      assert players_created == 0
    end
  end

  describe "purge/0" do
    test "removes exactly the demo players and returns their count" do
      Demo.seed()

      # Confirm they're there before purge
      assert Accounts.get_player_by_email("sav@demo.predictex.local") != nil

      count = Demo.purge()

      assert count == 6
      assert Accounts.get_player_by_email("sav@demo.predictex.local") == nil
      assert Accounts.get_player_by_email("dave@demo.predictex.local") == nil
    end

    test "purge does not remove non-demo players or their predictions", %{f1: f1} do
      Demo.seed()
      real_player = player_fixture(%{email: "real@example.com", display_name: "Real"})

      {:ok, _} =
        Predictions.admin_upsert_prediction(%{
          player_id: real_player.id,
          fixture_id: f1.id,
          home_goals: 1,
          away_goals: 0
        })

      Demo.purge()

      surviving = Accounts.get_player_by_email("real@example.com")
      assert surviving != nil
      assert surviving.display_name == "Real"

      surviving_preds = Predictions.list_player_predictions(real_player.id)
      assert length(surviving_preds) == 1
    end

    test "purge on empty returns 0" do
      assert Demo.purge() == 0
    end
  end

  describe "demo?/1" do
    test "returns true for a demo domain player" do
      Demo.seed()
      player = Accounts.get_player_by_email("sav@demo.predictex.local")
      assert Demo.demo?(player)
    end

    test "returns false for a real player" do
      real = player_fixture(%{email: "real@example.com"})
      refute Demo.demo?(real)
    end
  end
end
