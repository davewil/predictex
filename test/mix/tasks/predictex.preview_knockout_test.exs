defmodule Mix.Tasks.Predictex.PreviewKnockoutTest do
  use Predictex.DataCase, async: true

  import Ecto.Query, warn: false

  alias Mix.Tasks.Predictex.PreviewKnockout
  alias Predictex.{Knockout, Repo}
  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture

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
      # "1A" / "2B" are bracket placeholders — Knockout.resolved_team?/1 returns false.
      team1: "1A",
      team2: "2B",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  # First KO round (ordinal 4) with two unresolved (placeholder) fixtures, inserted ascending.
  defp ko_round_with_fixtures do
    r32 = round!(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    fixture!(r32, %{})
    fixture!(r32, %{})
    r32
  end

  test "resolves real team names onto the first two unresolved R32 fixtures" do
    r32 = ko_round_with_fixtures()

    assert {:ok, result} = PreviewKnockout.open_first_knockout_round()

    assert result.round.id == r32.id
    assert result.resolved_count == 2

    fixtures = Repo.all(from f in Fixture, where: f.round_id == ^r32.id)

    assert Enum.all?(fixtures, fn f ->
             Knockout.resolved_team?(f.team1) and Knockout.resolved_team?(f.team2)
           end)
  end

  test "is idempotent — a second run finds no unresolved fixtures and resolves none" do
    ko_round_with_fixtures()

    assert {:ok, %{resolved_count: 2}} = PreviewKnockout.open_first_knockout_round()
    assert {:ok, second} = PreviewKnockout.open_first_knockout_round()

    assert second.resolved_count == 0
  end

  test "raises a clear error when no knockout round exists" do
    round!(%{name: "Round 1", stage: :group, ordinal: 1})

    assert_raise Mix.Error, ~r/no knockout round/i, fn ->
      PreviewKnockout.open_first_knockout_round()
    end
  end
end
