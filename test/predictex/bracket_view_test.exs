defmodule Predictex.BracketViewTest do
  use Predictex.DataCase, async: true

  alias Predictex.{Bracket, Tournament}

  defp fixture!(round, attrs) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  test "view/0 reads the live fixtures and projects the R32" do
    {:ok, g1} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    {:ok, r32} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})

    fixture!(g1, %{
      group: "C",
      team1: "Croatia",
      team2: "Belgium",
      home_goals: 2,
      away_goals: 0,
      status: :completed
    })

    fixture!(r32, %{team1: "1C", team2: "2C", source_num: 73})

    %{matches: [match], group_tables: tables} = Bracket.view()

    assert match.home == {:exact, "Croatia"}
    assert match.away == {:exact, "Belgium"}
    assert Map.has_key?(tables, "C")
  end
end
