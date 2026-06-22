defmodule Predictex.RankingTest do
  @moduledoc """
  The shared, pure ranking core. Both `Predictex.Standings` (FK join) and
  `Predictex.Leaderboard` (team-name join) feed it already-joined `scored`
  entries plus the round fixture universe; it owns the fold — fixtures total,
  the Round Bonus completeness rule, the total, and the sort.

  Inputs are hand-built `%{ordinal, result}` maps (no real fixtures), which is
  the whole point of the seam: the must-not-drift ranking laws are testable
  without constructing scoreable fixtures.
  """
  use ExUnit.Case, async: true

  alias Predictex.Ranking

  # A scoring result as `Scoring.score/3` would return it — only the two fields
  # the core reads.
  defp res(total, correct?), do: %{fixture_total: total, outcome_correct: correct?}

  # The fixture universe entry the core groups into round meta.
  defp rf(ordinal, completed?), do: %{ordinal: ordinal, completed?: completed?}

  describe "fixtures_total" do
    test "sums each scored entry's fixture_total" do
      players = [
        %{
          name: "Dave",
          scored: [%{ordinal: 1, result: res(30, true)}, %{ordinal: 1, result: res(10, false)}]
        }
      ]

      assert [%{fixtures_total: 40}] = Ranking.rank(players, [rf(1, true), rf(1, true)])
    end

    test "an empty scored list scores zero" do
      players = [%{name: "Dave", scored: []}]
      assert [%{fixtures_total: 0, round_bonus_total: 0, total: 0}] = Ranking.rank(players, [])
    end
  end

  describe "round bonus" do
    # Round 1 = two fixtures; the player predicts both, both completed.
    test "awards +20 when a complete round is fully and correctly predicted" do
      players = [
        %{
          name: "Dave",
          scored: [%{ordinal: 1, result: res(30, true)}, %{ordinal: 1, result: res(30, true)}]
        }
      ]

      [dave] = Ranking.rank(players, [rf(1, true), rf(1, true)])
      assert dave.round_bonus_total == 20
      assert dave.bonus_by_round == %{1 => 20}
      assert dave.total == 80
    end

    test "no bonus when the round is incomplete" do
      players = [
        %{
          name: "Dave",
          scored: [%{ordinal: 1, result: res(30, true)}, %{ordinal: 1, result: res(30, true)}]
        }
      ]

      # one of the round's fixtures is not completed
      [dave] = Ranking.rank(players, [rf(1, true), rf(1, false)])
      assert dave.round_bonus_total == 0
    end

    test "no bonus when a fixture in the round was left unpredicted" do
      players = [%{name: "Dave", scored: [%{ordinal: 1, result: res(30, true)}]}]

      # round has two fixtures; the player only scored one of them
      [dave] = Ranking.rank(players, [rf(1, true), rf(1, true)])
      assert dave.round_bonus_total == 0
    end

    test "no bonus when an outcome in the round is wrong" do
      players = [
        %{
          name: "Dave",
          scored: [%{ordinal: 1, result: res(30, true)}, %{ordinal: 1, result: res(10, false)}]
        }
      ]

      [dave] = Ranking.rank(players, [rf(1, true), rf(1, true)])
      assert dave.round_bonus_total == 0
    end

    test "a nil ordinal never earns a bonus" do
      players = [%{name: "Dave", scored: [%{ordinal: nil, result: res(30, true)}]}]

      [dave] = Ranking.rank(players, [rf(nil, true)])
      assert dave.round_bonus_total == 0
      assert dave.bonus_by_round == %{nil => 0}
    end

    test "sums the bonus across multiple complete rounds" do
      players = [
        %{
          name: "Dave",
          scored: [
            %{ordinal: 1, result: res(30, true)},
            %{ordinal: 1, result: res(30, true)},
            %{ordinal: 2, result: res(30, true)}
          ]
        }
      ]

      round_fixtures = [rf(1, true), rf(1, true), rf(2, true)]
      [dave] = Ranking.rank(players, round_fixtures)
      assert dave.bonus_by_round == %{1 => 20, 2 => 20}
      assert dave.round_bonus_total == 40
      # fixtures 90 + bonus 40
      assert dave.total == 130
    end
  end

  describe "ranking" do
    test "sorts by total descending, ties broken by name" do
      players = [
        %{name: "Bea", scored: [%{ordinal: 1, result: res(10, false)}]},
        %{name: "Zara", scored: [%{ordinal: 1, result: res(10, false)}]},
        %{name: "Amy", scored: [%{ordinal: 1, result: res(30, true)}]}
      ]

      ranked = Ranking.rank(players, [rf(1, true)])
      assert Enum.map(ranked, & &1.name) == ["Amy", "Bea", "Zara"]
    end
  end

  describe "echo contract" do
    test "echoes caller-supplied identity fields (e.g. player_id) onto the entry" do
      players = [%{player_id: 7, name: "Dave", scored: [%{ordinal: 1, result: res(30, true)}]}]

      assert [%{player_id: 7, name: "Dave"}] = Ranking.rank(players, [rf(1, true)])
    end

    test "breakdown echoes the scored entries verbatim, preserving extra keys" do
      players = [
        %{name: "Dave", scored: [%{ordinal: 1, fixture_id: 99, result: res(30, true)}]}
      ]

      [dave] = Ranking.rank(players, [rf(1, true)])
      assert dave.breakdown == [%{ordinal: 1, fixture_id: 99, result: res(30, true)}]
      # :scored is folded into :breakdown, not left on the entry
      refute Map.has_key?(dave, :scored)
    end
  end
end
