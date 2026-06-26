defmodule PredictexWeb.BracketLiveTest do
  use PredictexWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias Predictex.Tournament

  defp fixture!(round, attrs) do
    base = %{
      external_ref: "ref-#{System.unique_integer([:positive])}",
      status: :scheduled,
      round_id: round.id
    }

    {:ok, f} = Tournament.create_fixture(Map.merge(base, attrs))
    f
  end

  setup do
    # Rounds ascending by ordinal (DataCase deadlock invariant).
    {:ok, g1} = Tournament.create_round(%{name: "Matchday 1", stage: :group, ordinal: 1})
    {:ok, r32} = Tournament.create_round(%{name: "Round of 32", stage: :knockout, ordinal: 4})
    %{g1: g1, r32: r32}
  end

  test "is public — renders without logging in", %{conn: conn, g1: g1, r32: r32} do
    fixture!(g1, %{
      group: "C",
      team1: "Croatia",
      team2: "Belgium",
      home_goals: 2,
      away_goals: 0,
      status: :completed
    })

    fixture!(r32, %{team1: "1C", team2: "3A/B/C/D/F", source_num: 73})

    {:ok, _lv, html} = live(conn, ~p"/bracket")

    assert html =~ "As it stands"
    assert html =~ "Croatia"
    # Third-placed slot shows the candidate set, not a guessed team.
    assert html =~ "A/B/C/D/F"
    # Group table is present.
    assert html =~ "Belgium"
  end

  test "re-pulls on a fixtures_changed broadcast", %{conn: conn, g1: g1, r32: r32} do
    pred =
      fixture!(g1, %{
        group: "C",
        team1: "Croatia",
        team2: "Belgium",
        kickoff_at: nil,
        status: :scheduled
      })

    fixture!(r32, %{team1: "1C", team2: "2C", source_num: 73})

    {:ok, lv, _html} = live(conn, ~p"/bracket")

    # Settle the group fixture, then broadcast the same signal the settle path emits.
    pred
    |> Ecto.Changeset.change(%{status: :completed, home_goals: 3, away_goals: 0})
    |> Predictex.Repo.update!()

    Tournament.broadcast_change()

    html = render(lv)
    # Croatia is now the group winner → fills the 1C slot.
    assert html =~ "Croatia"
  end
end
