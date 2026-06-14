defmodule Predictex.TournamentTest do
  use Predictex.DataCase, async: true

  alias Predictex.Tournament

  defp round!(attrs \\ %{}) do
    {:ok, r} = Tournament.create_round(Map.merge(%{name: "Round 1", stage: :group, ordinal: 1}, attrs))
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

  describe "round_open?/1 and round_complete?/1" do
    test "group rounds are always open" do
      assert Tournament.round_open?(round!(%{stage: :group, ordinal: 1}))
    end

    test "a knockout round is closed until the previous round completes" do
      r4 = round!(%{name: "Round of 32", stage: :knockout, ordinal: 4})
      r5 = round!(%{name: "Round of 16", stage: :knockout, ordinal: 5})
      f = fixture!(r4, %{status: :scheduled})

      refute Tournament.round_open?(r5)

      {:ok, _} = Tournament.update_fixture(f, %{status: :completed, home_goals: 1, away_goals: 0})
      assert Tournament.round_open?(r5)
    end

    test "round_complete? is false for a round with no fixtures" do
      refute Tournament.round_complete?(round!(%{ordinal: 2, name: "Round 2"}))
    end
  end

  describe "fixtures" do
    test "external_ref is unique" do
      r = round!()
      fixture!(r, %{external_ref: "dup"})

      assert {:error, cs} =
               Tournament.create_fixture(%{external_ref: "dup", team1: "A", team2: "B", status: :scheduled, round_id: r.id})

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
end
