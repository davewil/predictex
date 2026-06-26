defmodule Predictex.TournamentTest do
  use Predictex.DataCase, async: true

  alias Predictex.Tournament

  defp round!(attrs \\ %{}) do
    {:ok, r} =
      Tournament.create_round(Map.merge(%{name: "Round 1", stage: :group, ordinal: 1}, attrs))

    r
  end

  defp fixture!(round, attrs) do
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

  describe "rounds" do
    test "ordinal must be within 1..8" do
      assert {:error, cs} = Tournament.create_round(%{name: "X", stage: :group, ordinal: 9})
      assert %{ordinal: ["is invalid"]} = errors_on(cs)
    end

    test "ordinal is unique" do
      round!(%{ordinal: 1})
      assert {:error, cs} = Tournament.create_round(%{name: "dup", stage: :group, ordinal: 1})
      assert %{ordinal: ["has already been taken"]} = errors_on(cs)
    end
  end

  describe "fixtures" do
    test "external_ref is unique" do
      r = round!()
      fixture!(r, %{external_ref: "dup"})

      assert {:error, cs} =
               Tournament.create_fixture(%{
                 external_ref: "dup",
                 team1: "A",
                 team2: "B",
                 status: :scheduled,
                 round_id: r.id
               })

      assert %{external_ref: ["has already been taken"]} = errors_on(cs)
    end

    test "cohort percentages must be within 0..100" do
      r = round!()

      assert {:error, cs} =
               Tournament.create_fixture(%{
                 external_ref: "x",
                 team1: "A",
                 team2: "B",
                 status: :scheduled,
                 round_id: r.id,
                 cohort_home_pct: 150
               })

      assert Map.has_key?(errors_on(cs), :cohort_home_pct)
    end
  end

  describe "fixture-change pub/sub (predictex-9p0)" do
    test "broadcast_change/0 notifies a subscriber of subscribe_changes/0" do
      assert :ok = Tournament.subscribe_changes()
      assert :ok = Tournament.broadcast_change()
      # assert_received (not assert_receive): broadcast is synchronous on the local node, so the
      # message is already in the mailbox — no timeout window for a concurrent async test to race.
      assert_received :fixtures_changed
    end
  end

  describe "group_stage_fixtures/0 and r32_fixtures/0" do
    test "partitions group-stage from the first knockout round" do
      # Insert rounds ascending by ordinal (DataCase deadlock invariant).
      {:ok, g1} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
      {:ok, r32} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
      {:ok, r16} = Tournament.create_round(%{name: "Round of 16", stage: :knockout, ordinal: 5})

      gf = fixture!(g1, %{group: "A"})
      k_b = fixture!(r32, %{team1: "1A", team2: "2B", source_num: 74})
      k_a = fixture!(r32, %{team1: "1C", team2: "2D", source_num: 73})
      _r16f = fixture!(r16, %{team1: "W73", team2: "W74", source_num: 89})

      assert Enum.map(Tournament.group_stage_fixtures(), & &1.id) == [gf.id]
      # R32 = lowest-ordinal knockout round, ordered by source_num.
      assert Enum.map(Tournament.r32_fixtures(), & &1.id) == [k_a.id, k_b.id]
    end

    test "r32_fixtures is empty when there is no knockout round" do
      {:ok, g1} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
      _gf = fixture!(g1, %{group: "A"})
      assert Tournament.r32_fixtures() == []
    end
  end
end
