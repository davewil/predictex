defmodule Predictex.PredictionsTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Predictions, Tournament}
  alias Predictex.Tournament.Fixture

  import Predictex.AccountsFixtures

  setup do
    {:ok, round} = Tournament.create_round(%{name: "Round 1", stage: :group, ordinal: 1})
    player = player_fixture(%{display_name: "Dave"})
    %{round: round, player: player}
  end

  defp fixture!(round, attrs \\ %{}) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      team1: "A",
      team2: "B",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  test "create_prediction sets round_id from the fixture", %{round: round, player: player} do
    f = fixture!(round)

    {:ok, pred} =
      Predictions.create_prediction(%{
        player_id: player.id,
        fixture_id: f.id,
        home_goals: 1,
        away_goals: 0
      })

    assert pred.round_id == round.id
  end

  test "rejects a prediction with more than 9 goals", %{round: round, player: player} do
    f = fixture!(round)

    assert {:error, cs} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 10,
               away_goals: 0
             })

    assert %{home_goals: ["must be less than or equal to 9"]} = errors_on(cs)
  end

  test "accepts boundary goal values 0 and 9", %{round: round, player: player} do
    f = fixture!(round)

    assert {:ok, _} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 9,
               away_goals: 0
             })
  end

  test "only one prediction per player per fixture", %{round: round, player: player} do
    f = fixture!(round)

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: player.id,
        fixture_id: f.id,
        home_goals: 1,
        away_goals: 0
      })

    assert {:error, cs} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 2,
               away_goals: 2
             })

    assert %{player_id: ["already predicted this fixture"]} = errors_on(cs)
  end

  test "only one booster per player per round", %{round: round, player: player} do
    f1 = fixture!(round)
    f2 = fixture!(round)

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: player.id,
        fixture_id: f1.id,
        home_goals: 1,
        away_goals: 0,
        booster: true
      })

    assert {:error, cs} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f2.id,
               home_goals: 0,
               away_goals: 0,
               booster: true
             })

    assert %{player_id: ["booster already used in this round"]} = errors_on(cs)
  end

  test "two non-boosted predictions in the same round are allowed", %{
    round: round,
    player: player
  } do
    f1 = fixture!(round)
    f2 = fixture!(round)

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: player.id,
        fixture_id: f1.id,
        home_goals: 1,
        away_goals: 0
      })

    assert {:ok, _} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f2.id,
               home_goals: 0,
               away_goals: 0
             })
  end

  test "predictions lock at kickoff", %{round: round, player: player} do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{kickoff_at: past})

    assert {:error, :locked} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 1,
               away_goals: 0
             })
  end

  test "predictions are open before kickoff", %{round: round, player: player} do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    f = fixture!(round, %{kickoff_at: future})

    assert {:ok, _} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: f.id,
               home_goals: 1,
               away_goals: 0
             })
  end

  test "an unknown fixture is rejected", %{player: player} do
    assert {:error, :fixture_not_found} =
             Predictions.create_prediction(%{
               player_id: player.id,
               fixture_id: 999_999,
               home_goals: 1,
               away_goals: 0
             })
  end

  test "list_player_predictions returns only that player's predictions", %{
    round: round,
    player: player
  } do
    other = player_fixture(%{display_name: "Other"})
    f1 = fixture!(round)
    f2 = fixture!(round)

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: player.id,
        fixture_id: f1.id,
        home_goals: 1,
        away_goals: 0
      })

    {:ok, _} =
      Predictions.create_prediction(%{
        player_id: other.id,
        fixture_id: f2.id,
        home_goals: 2,
        away_goals: 2
      })

    preds = Predictions.list_player_predictions(player.id)
    assert length(preds) == 1
    assert hd(preds).fixture_id == f1.id
  end

  describe "cta_window?/2 (live drill-down CTA visibility)" do
    @kickoff ~U[2026-06-18 19:00:00Z]

    test "false more than 30 minutes before kickoff" do
      now = DateTime.add(@kickoff, -31 * 60, :second)
      refute Predictions.cta_window?(%Fixture{kickoff_at: @kickoff}, now)
    end

    test "true at exactly 30 minutes before kickoff (boundary)" do
      now = DateTime.add(@kickoff, -30 * 60, :second)
      assert Predictions.cta_window?(%Fixture{kickoff_at: @kickoff}, now)
    end

    test "true within the 30-minute pre-kickoff window" do
      now = DateTime.add(@kickoff, -5 * 60, :second)
      assert Predictions.cta_window?(%Fixture{kickoff_at: @kickoff}, now)
    end

    test "true while the match is live (after kickoff)" do
      now = DateTime.add(@kickoff, 50 * 60, :second)
      assert Predictions.cta_window?(%Fixture{kickoff_at: @kickoff}, now)
    end

    test "true long after kickoff (open-ended, for the post-match recap)" do
      now = DateTime.add(@kickoff, 3 * 24 * 60 * 60, :second)
      assert Predictions.cta_window?(%Fixture{kickoff_at: @kickoff}, now)
    end

    test "false when kickoff is unknown" do
      refute Predictions.cta_window?(%Fixture{kickoff_at: nil}, DateTime.utc_now())
    end
  end

  describe "save_round_predictions/4 (member, lockout-aware)" do
    setup %{round: round} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      open = fixture!(round, %{kickoff_at: future})
      locked = fixture!(round, %{kickoff_at: past})
      %{open: open, locked: locked}
    end

    test "saves picks for unlocked fixtures", %{round: round, player: player, open: open} do
      rows = [%{fixture_id: open.id, home_goals: 2, away_goals: 1, booster: false}]
      assert {:ok, results} = Predictions.save_round_predictions(player.id, round.id, rows, true)
      assert results[open.id] == :upserted
      assert Predictions.get_player_fixture_prediction(player.id, open.id).home_goals == 2
    end

    test "refuses to write a locked fixture", %{round: round, player: player, locked: locked} do
      rows = [%{fixture_id: locked.id, home_goals: 9, away_goals: 9, booster: false}]
      assert {:ok, results} = Predictions.save_round_predictions(player.id, round.id, rows, true)
      assert results[locked.id] == :locked
      assert Predictions.get_player_fixture_prediction(player.id, locked.id) == nil
    end

    test "a booster on a locked fixture is preserved when other rows save", %{
      round: round,
      player: player,
      open: open,
      locked: locked
    } do
      # Pre-existing booster on the (now) locked fixture, written while it was open.
      {:ok, _} =
        Predictions.admin_upsert_prediction(%{
          player_id: player.id,
          fixture_id: locked.id,
          home_goals: 1,
          away_goals: 0,
          booster: true
        })

      rows = [%{fixture_id: open.id, home_goals: 0, away_goals: 0, booster: false}]
      assert {:ok, _} = Predictions.save_round_predictions(player.id, round.id, rows, true)

      # The locked fixture keeps its booster — the member can't move it.
      assert Predictions.get_player_fixture_prediction(player.id, locked.id).booster == true
    end

    # --- write-auth seam: out-of-round fixture rejection (fix for server-side trust boundary) ---

    test "a fixture from a different round is rejected as :unknown and never written", %{
      round: round,
      player: player
    } do
      # Create a second round with its own fixture — foreign to `round`.
      {:ok, other_round} =
        Tournament.create_round(%{name: "Other Round", stage: :group, ordinal: 2})

      foreign_fixture = fixture!(other_round)

      rows = [%{fixture_id: foreign_fixture.id, home_goals: 2, away_goals: 1, booster: false}]

      assert {:ok, results} = Predictions.save_round_predictions(player.id, round.id, rows, true)
      assert results[foreign_fixture.id] == :unknown
      assert Predictions.get_player_fixture_prediction(player.id, foreign_fixture.id) == nil
    end

    test "a non-existent fixture_id is rejected as :unknown and never written", %{
      round: round,
      player: player
    } do
      nonexistent_id = 999_999_999

      rows = [%{fixture_id: nonexistent_id, home_goals: 2, away_goals: 1, booster: false}]

      assert {:ok, results} = Predictions.save_round_predictions(player.id, round.id, rows, true)
      assert results[nonexistent_id] == :unknown
      assert Predictions.get_player_fixture_prediction(player.id, nonexistent_id) == nil
    end

    test "a normal in-round open fixture still saves as :upserted", %{
      round: round,
      player: player,
      open: open
    } do
      rows = [%{fixture_id: open.id, home_goals: 3, away_goals: 0, booster: false}]
      assert {:ok, results} = Predictions.save_round_predictions(player.id, round.id, rows, true)
      assert results[open.id] == :upserted
      assert Predictions.get_player_fixture_prediction(player.id, open.id).home_goals == 3
    end

    # Defense-in-depth write gate (predictex-5q6): with the :native_ko_entry flag resolved
    # off for the actor, the write is rejected before any DB work — independent of the
    # LiveView render guard, so a crafted save_round event can't bypass a dark flag.
    test "rejects the whole write when the feature gate is off (no DB writes)", %{
      round: round,
      player: player,
      open: open
    } do
      rows = [%{fixture_id: open.id, home_goals: 2, away_goals: 1, booster: false}]

      assert {:error, :feature_disabled} =
               Predictions.save_round_predictions(player.id, round.id, rows, false)

      assert Predictions.get_player_fixture_prediction(player.id, open.id) == nil
    end

    test "a row for an unresolved (placeholder-team) fixture is rejected as :pending and never written",
         %{round: round, player: player} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      pending = fixture!(round, %{team1: "1A", team2: "2B", kickoff_at: future})
      rows = [%{fixture_id: pending.id, home_goals: 2, away_goals: 1, booster: false}]

      assert {:ok, results} = Predictions.save_round_predictions(player.id, round.id, rows, true)
      assert results[pending.id] == :pending
      assert Predictions.get_player_fixture_prediction(player.id, pending.id) == nil
    end

    test "rejects :booster_locked when a kicked-off fixture already holds the booster",
         %{round: round, player: player, open: open, locked: locked} do
      # Commit the booster to the locked (kicked-off) fixture, as a prior save would have.
      {:ok, _} =
        Predictions.admin_upsert_prediction(%{
          player_id: player.id,
          fixture_id: locked.id,
          home_goals: 1,
          away_goals: 0,
          booster: true
        })

      # Now try to boost the still-open fixture.
      rows = [%{fixture_id: open.id, home_goals: 2, away_goals: 1, booster: true}]

      assert {:error, :booster_locked} =
               Predictions.save_round_predictions(player.id, round.id, rows, true)

      # The committed booster on the locked fixture survives; nothing was written to `open`.
      assert Predictions.get_player_fixture_prediction(player.id, locked.id).booster == true
      assert Predictions.get_player_fixture_prediction(player.id, open.id) == nil
    end
  end

  describe "prediction writes broadcast a coarse fixture-change (live dashboards re-pull)" do
    # The gap predictex-4ez scoping surfaced: only result-settle paths broadcast, so an
    # admin entering/importing a prediction on an already-completed fixture changed the
    # standings while open `/predictions` sessions stayed stale. Every successful write
    # now emits the same coarse `:fixtures_changed` signal the settle path uses (9p0).
    # assert_received: the broadcast is synchronous on the local node — no async window.

    test "create_prediction broadcasts on success", %{round: round, player: player} do
      f = fixture!(round)
      Tournament.subscribe_changes()

      {:ok, _} =
        Predictions.create_prediction(%{
          player_id: player.id,
          fixture_id: f.id,
          home_goals: 1,
          away_goals: 0
        })

      assert_received :fixtures_changed
    end

    test "create_prediction does NOT broadcast on a failed (locked) write", %{
      round: round,
      player: player
    } do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      f = fixture!(round, %{kickoff_at: past})
      Tournament.subscribe_changes()

      assert {:error, :locked} =
               Predictions.create_prediction(%{
                 player_id: player.id,
                 fixture_id: f.id,
                 home_goals: 1,
                 away_goals: 0
               })

      refute_received :fixtures_changed
    end

    test "admin_upsert_prediction broadcasts on success", %{round: round, player: player} do
      f = fixture!(round)
      Tournament.subscribe_changes()

      {:ok, _} =
        Predictions.admin_upsert_prediction(%{
          player_id: player.id,
          fixture_id: f.id,
          home_goals: 2,
          away_goals: 1
        })

      assert_received :fixtures_changed
    end

    test "admin_save_round_predictions broadcasts on success", %{round: round, player: player} do
      f = fixture!(round)
      Tournament.subscribe_changes()

      rows = [%{fixture_id: f.id, home_goals: 1, away_goals: 1, booster: false}]
      assert {:ok, _} = Predictions.admin_save_round_predictions(player.id, round.id, rows)

      assert_received :fixtures_changed
    end

    test "save_round_predictions broadcasts on success", %{round: round, player: player} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      f = fixture!(round, %{kickoff_at: future})
      Tournament.subscribe_changes()

      rows = [%{fixture_id: f.id, home_goals: 2, away_goals: 0, booster: false}]
      assert {:ok, _} = Predictions.save_round_predictions(player.id, round.id, rows, true)

      assert_received :fixtures_changed
    end
  end

  describe "get_player_fixture_prediction/2 (anti-copy focused getter)" do
    test "returns the player's own prediction for the fixture", %{round: round, player: player} do
      f = fixture!(round)

      {:ok, pred} =
        Predictions.create_prediction(%{
          player_id: player.id,
          fixture_id: f.id,
          home_goals: 2,
          away_goals: 1
        })

      got = Predictions.get_player_fixture_prediction(player.id, f.id)
      assert got.id == pred.id
      assert got.home_goals == 2
      assert got.away_goals == 1
    end

    test "returns nil when the player has no pick for the fixture", %{
      round: round,
      player: player
    } do
      f = fixture!(round)
      assert Predictions.get_player_fixture_prediction(player.id, f.id) == nil
    end

    test "does not return another player's pick for the same fixture", %{
      round: round,
      player: player
    } do
      other = player_fixture(%{display_name: "Other", email: "other@b.c"})
      f = fixture!(round)

      {:ok, _} =
        Predictions.create_prediction(%{
          player_id: other.id,
          fixture_id: f.id,
          home_goals: 0,
          away_goals: 0
        })

      assert Predictions.get_player_fixture_prediction(player.id, f.id) == nil
    end
  end

  describe "parse_pick_rows/2 (pure prediction-intake boundary)" do
    test "parses raw string params into typed pick rows" do
      picks = %{
        "10" => %{
          "home_goals" => "2",
          "away_goals" => "1",
          "first_scorer_side" => "home",
          "first_scorer_player" => "Messi"
        },
        "11" => %{
          "home_goals" => "0",
          "away_goals" => "0",
          "first_scorer_side" => "away",
          "first_scorer_player" => ""
        }
      }

      assert {:ok, rows} = Predictions.parse_pick_rows(picks, "10")
      by_id = Map.new(rows, &{&1.fixture_id, &1})

      assert by_id[10] == %{
               fixture_id: 10,
               home_goals: 2,
               away_goals: 1,
               first_scorer_side: :home,
               first_scorer_player: "Messi",
               first_scorer_fifaid: nil,
               booster: true
             }

      assert by_id[11] == %{
               fixture_id: 11,
               home_goals: 0,
               away_goals: 0,
               first_scorer_side: :away,
               first_scorer_player: nil,
               first_scorer_fifaid: nil,
               booster: false
             }
    end

    test "keeps blank-goal rows (the persistence layer decides to skip them)" do
      picks = %{"10" => %{"home_goals" => "", "away_goals" => ""}}

      assert {:ok, [row]} = Predictions.parse_pick_rows(picks, nil)
      assert row.fixture_id == 10
      assert row.home_goals == nil and row.away_goals == nil
      assert row.booster == false
    end

    test "rejects a booster on a blank scoreline (booster-on-blank invariant)" do
      picks = %{"10" => %{"home_goals" => "", "away_goals" => ""}}
      assert {:error, :booster_on_blank} = Predictions.parse_pick_rows(picks, "10")
    end

    test "carries first_scorer_fifaid (parsed to integer) into the row" do
      picks = %{
        "10" => %{
          "home_goals" => "1",
          "away_goals" => "0",
          "first_scorer_player" => "Neymar",
          "first_scorer_fifaid" => "100002"
        }
      }

      assert {:ok, [row]} = Predictions.parse_pick_rows(picks, nil)
      assert row.first_scorer_player == "Neymar"
      assert row.first_scorer_fifaid == 100_002
    end

    test "blank first_scorer_fifaid parses to nil" do
      picks = %{"10" => %{"home_goals" => "1", "away_goals" => "0", "first_scorer_fifaid" => ""}}
      assert {:ok, [row]} = Predictions.parse_pick_rows(picks, nil)
      assert row.first_scorer_fifaid == nil
    end

    test "skips a forged non-integer fixture key instead of crashing" do
      picks = %{
        "not-an-int" => %{"home_goals" => "1", "away_goals" => "0"},
        "10" => %{"home_goals" => "2", "away_goals" => "2"}
      }

      assert {:ok, rows} = Predictions.parse_pick_rows(picks, nil)
      assert Enum.map(rows, & &1.fixture_id) == [10]
    end
  end

  describe "validate_pick_rows/1 (pure invariant owner)" do
    test "ok when no booster sits on a blank row" do
      rows = [
        %{fixture_id: 1, home_goals: 1, away_goals: 0, booster: true},
        %{fixture_id: 2, home_goals: nil, away_goals: nil, booster: false}
      ]

      assert {:ok, ^rows} = Predictions.validate_pick_rows(rows)
    end

    test "error when a booster sits on a blank row" do
      rows = [%{fixture_id: 1, home_goals: nil, away_goals: nil, booster: true}]
      assert {:error, :booster_on_blank} = Predictions.validate_pick_rows(rows)
    end
  end

  describe "fixture_entry_state/2 (per-fixture KO entry gate)" do
    alias Predictex.Tournament.Fixture

    @now ~U[2026-06-28 12:00:00Z]

    test ":pending when either team is still a bracket placeholder" do
      future = DateTime.add(@now, 3600, :second)

      assert Predictions.fixture_entry_state(
               %Fixture{team1: "Germany", team2: "3A/B/C/D/F", kickoff_at: future},
               @now
             ) == :pending

      assert Predictions.fixture_entry_state(
               %Fixture{team1: "1C", team2: "Belgium", kickoff_at: future},
               @now
             ) == :pending
    end

    test ":editable when both teams resolved and kickoff is in the future" do
      future = DateTime.add(@now, 3600, :second)

      assert Predictions.fixture_entry_state(
               %Fixture{team1: "Brazil", team2: "Japan", kickoff_at: future},
               @now
             ) == :editable
    end

    test ":locked when both teams resolved and kickoff has passed" do
      past = DateTime.add(@now, -3600, :second)

      assert Predictions.fixture_entry_state(
               %Fixture{team1: "Brazil", team2: "Japan", kickoff_at: past},
               @now
             ) == :locked
    end

    test ":pending takes precedence over a passed kickoff" do
      past = DateTime.add(@now, -3600, :second)

      assert Predictions.fixture_entry_state(
               %Fixture{team1: "1A", team2: "2B", kickoff_at: past},
               @now
             ) == :pending
    end
  end
end
