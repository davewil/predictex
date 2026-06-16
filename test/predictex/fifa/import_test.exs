defmodule Predictex.Fifa.ImportTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.Import
  alias Predictex.Tournament.Fixture

  defp fixture(id, team1, team2, kickoff, round_id),
    do: %Fixture{id: id, team1: team1, team2: team2, kickoff_at: kickoff, round_id: round_id}

  defp fifa_match(id, home, away, date),
    do: %{"id" => id, "homeSquadName" => home, "awaySquadName" => away, "date" => date}

  defp round(round_id, matches),
    do: %{"id" => round_id, "stage" => "group", "tournaments" => matches}

  defp payload_row(round, match_id, hs, as, booster),
    do: %{
      "round" => round,
      "matchId" => match_id,
      "homeScore" => hs,
      "awayScore" => as,
      "booster" => booster
    }

  describe "decode_payload/1" do
    test "decodes a base64url JSON array of rows" do
      rows = [payload_row(1, 1, 2, 0, true)]
      b64 = rows |> Jason.encode!() |> Base.url_encode64(padding: false)
      assert {:ok, ^rows} = Import.decode_payload(b64)
    end

    test "rejects non-base64 input" do
      assert {:error, :bad_payload} = Import.decode_payload("not base64 !!!")
    end

    test "rejects valid base64 that is not a JSON array" do
      b64 = "{}" |> Base.url_encode64(padding: false)
      assert {:error, :bad_payload} = Import.decode_payload(b64)
    end
  end

  describe "plan/3" do
    test "matches a group row to its fixture (positional, no swap)" do
      fx = fixture(7, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z], 1)
      rounds = [round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])]

      %{matched: [m], unmatched: []} = Import.plan([payload_row(1, 1, 2, 0, true)], rounds, [fx])

      assert m == %{
               fixture_id: 7,
               team1: "Mexico",
               team2: "South Africa",
               home_goals: 2,
               away_goals: 0,
               booster: true,
               round_id: 1
             }
    end

    test "scoreline follows the FIFA home team across an orientation swap" do
      fx = fixture(9, "Spain", "Iran", ~U[2026-06-20 19:00:00Z], 1)
      rounds = [round(1, [fifa_match(5, "Iran", "Spain", "2026-06-20T20:00:00+01:00")])]

      %{matched: [m]} = Import.plan([payload_row(1, 5, 1, 3, false)], rounds, [fx])
      assert m.home_goals == 3
      assert m.away_goals == 1
    end

    test "composite {round, matchId} key: same matchId in different rounds maps to distinct fixtures" do
      fx1 = fixture(1, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z], 1)
      fx2 = fixture(2, "Brazil", "Serbia", ~U[2026-06-18 19:00:00Z], 2)

      rounds = [
        round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")]),
        round(2, [fifa_match(1, "Brazil", "Serbia", "2026-06-18T20:00:00+01:00")])
      ]

      payload = [payload_row(1, 1, 2, 0, false), payload_row(2, 1, 1, 1, false)]
      %{matched: matched} = Import.plan(payload, rounds, [fx1, fx2])

      by_fixture = Map.new(matched, &{&1.fixture_id, &1})
      assert by_fixture[1].home_goals == 2
      assert by_fixture[2].home_goals == 1
    end

    test "unmatched reasons: unknown_match_id, out_of_scope, invalid, no_fixture" do
      fx = fixture(7, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z], 1)
      rounds = [round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])]

      assert %{unmatched: [%{reason: :unknown_match_id}]} =
               Import.plan([payload_row(1, 999, 1, 0, false)], rounds, [fx])

      assert %{unmatched: [%{reason: :out_of_scope}]} =
               Import.plan([payload_row(4, 1, 1, 0, false)], rounds, [fx])

      assert %{unmatched: [%{reason: :invalid}]} =
               Import.plan([payload_row(1, 1, nil, 0, false)], rounds, [fx])

      rounds_only = [round(1, [fifa_match(2, "Qatar", "Ecuador", "2026-06-12T20:00:00+01:00")])]

      assert %{unmatched: [%{reason: :no_fixture}]} =
               Import.plan([payload_row(1, 2, 1, 0, false)], rounds_only, [fx])
    end

    test "unmatched row carries booster so the UI can warn" do
      rounds = [round(1, [])]
      %{unmatched: [u]} = Import.plan([payload_row(1, 999, 2, 0, true)], rounds, [])
      assert u.booster == true
      assert u.reason == :unknown_match_id
    end

    test "resolution order: out_of_scope beats invalid (knockout round with a nil score)" do
      fx = fixture(7, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z], 1)
      rounds = [round(1, [fifa_match(1, "Mexico", "South Africa", "2026-06-11T20:00:00+01:00")])]
      # round 4 is knockout AND the score is nil; out_of_scope must win.
      assert %{unmatched: [%{reason: :out_of_scope}]} =
               Import.plan([payload_row(4, 1, nil, 0, false)], rounds, [fx])
    end

    test "a sparse row missing keys degrades safely to out_of_scope (no crash)" do
      assert %{matched: [], unmatched: [%{reason: :out_of_scope, booster: false}]} =
               Import.plan([%{"matchId" => 1}], [round(1, [])], [])
    end
  end

  describe "rows_from_envelope/2" do
    test "maps a FIFA envelope to plan rows, injecting the round" do
      envelope = %{
        "success" => %{
          "predictions" => [
            %{"matchId" => 1, "homeScore" => 2, "awayScore" => 0, "booster" => true},
            %{"matchId" => 2, "homeScore" => 1, "awayScore" => 1, "booster" => false}
          ]
        },
        "errors" => []
      }

      assert {:ok, rows} = Import.rows_from_envelope(envelope, 1)

      assert rows == [
               %{
                 "round" => 1,
                 "matchId" => 1,
                 "homeScore" => 2,
                 "awayScore" => 0,
                 "booster" => true
               },
               %{
                 "round" => 1,
                 "matchId" => 2,
                 "homeScore" => 1,
                 "awayScore" => 1,
                 "booster" => false
               }
             ]
    end

    test "accepts a bare predictions list too" do
      list = [%{"matchId" => 5, "homeScore" => 0, "awayScore" => 3, "booster" => false}]
      assert {:ok, [row]} = Import.rows_from_envelope(list, 2)

      assert row == %{
               "round" => 2,
               "matchId" => 5,
               "homeScore" => 0,
               "awayScore" => 3,
               "booster" => false
             }
    end

    test "coerces a missing/non-true booster to false" do
      envelope = %{
        "success" => %{"predictions" => [%{"matchId" => 1, "homeScore" => 1, "awayScore" => 0}]}
      }

      assert {:ok, [row]} = Import.rows_from_envelope(envelope, 1)
      assert row["booster"] == false
    end

    test "empty predictions yields an empty row list (not an error)" do
      assert {:ok, []} = Import.rows_from_envelope(%{"success" => %{"predictions" => []}}, 1)
    end

    test "rejects a shape that is neither an envelope nor a list" do
      assert {:error, :bad_envelope} = Import.rows_from_envelope(%{"oops" => true}, 1)
      assert {:error, :bad_envelope} = Import.rows_from_envelope("nope", 1)
    end

    test "ignores entries with no matchId rather than crashing" do
      envelope = %{"success" => %{"predictions" => [%{"homeScore" => 1, "awayScore" => 0}]}}
      assert {:ok, []} = Import.rows_from_envelope(envelope, 1)
    end
  end

  describe "to_write_rows/1" do
    test "groups matched entries by round_id, stripped to the write contract" do
      matched = [
        %{
          fixture_id: 7,
          team1: "A",
          team2: "B",
          home_goals: 2,
          away_goals: 0,
          booster: true,
          round_id: 1
        },
        %{
          fixture_id: 8,
          team1: "C",
          team2: "D",
          home_goals: 1,
          away_goals: 1,
          booster: false,
          round_id: 1
        },
        %{
          fixture_id: 9,
          team1: "E",
          team2: "F",
          home_goals: 0,
          away_goals: 0,
          booster: false,
          round_id: 2
        }
      ]

      grouped = Import.to_write_rows(matched)

      assert grouped[1] == [
               %{fixture_id: 7, home_goals: 2, away_goals: 0, booster: true},
               %{fixture_id: 8, home_goals: 1, away_goals: 1, booster: false}
             ]

      assert grouped[2] == [%{fixture_id: 9, home_goals: 0, away_goals: 0, booster: false}]
    end
  end
end
