defmodule Mix.Tasks.Predictex.PreviewKnockoutTest do
  use Predictex.DataCase, async: true

  alias Mix.Tasks.Predictex.PreviewKnockout
  alias Predictex.Tournament

  # Mirrors the round!/fixture! helpers in tournament_test.exs. Rounds are
  # inserted ascending by :ordinal (the DataCase deadlock invariant).
  defp round!(attrs) do
    {:ok, r} =
      Tournament.create_round(Map.merge(%{name: "Round", stage: :group, ordinal: 1}, attrs))

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

  # Predecessor group round (ordinal 3, incomplete) + first KO round (ordinal 4),
  # inserted ascending. R32 is gated shut until the group round completes.
  defp gated_r32 do
    group = round!(%{name: "Round 3", stage: :group, ordinal: 3})
    fixture!(group, %{status: :scheduled})
    fixture!(group, %{status: :scheduled})
    r32 = round!(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    {group, r32}
  end

  test "settles the predecessor group round so the first knockout round opens" do
    {_group, r32} = gated_r32()
    refute Tournament.round_open?(r32)

    assert {:ok, result} = PreviewKnockout.open_first_knockout_round()

    assert result.round.id == r32.id
    assert result.settled_count == 2
    assert result.already_complete == false
    assert Tournament.round_open?(r32)
  end

  test "settles via the real path — predecessor fixtures are :completed with goals set" do
    {group, _r32} = gated_r32()

    assert {:ok, _} = PreviewKnockout.open_first_knockout_round()

    for f <- Repo.all(from f in Predictex.Tournament.Fixture, where: f.round_id == ^group.id) do
      assert f.status == :completed
      assert is_integer(f.home_goals)
      assert is_integer(f.away_goals)
    end
  end

  test "is idempotent — a second run settles nothing and the round stays open" do
    {_group, r32} = gated_r32()

    assert {:ok, %{settled_count: 2}} = PreviewKnockout.open_first_knockout_round()
    assert {:ok, second} = PreviewKnockout.open_first_knockout_round()

    assert second.settled_count == 0
    assert second.already_complete == true
    assert Tournament.round_open?(r32)
  end

  test "raises a clear error when no knockout round exists" do
    round!(%{name: "Round 1", stage: :group, ordinal: 1})

    assert_raise Mix.Error, ~r/no knockout round/i, fn ->
      PreviewKnockout.open_first_knockout_round()
    end
  end

  test "raises a clear error when the predecessor round is missing" do
    # KO round at ordinal 4 but no ordinal-3 predecessor (partially-seeded DB)
    round!(%{name: "Round of 32", stage: :knockout, ordinal: 4})

    assert_raise Mix.Error, ~r/predecessor/i, fn ->
      PreviewKnockout.open_first_knockout_round()
    end
  end
end
