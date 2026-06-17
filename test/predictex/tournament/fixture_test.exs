defmodule Predictex.Tournament.FixtureTest do
  use Predictex.DataCase, async: true
  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture

  test "update_fixture/2 accepts live_* and fifa_match_id" do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, f} =
      Tournament.create_fixture(%{
        external_ref: "x", team1: "A", team2: "B", round_id: r.id,
        kickoff_at: ~U[2026-06-17 17:00:00Z]
      })

    {:ok, f} =
      Tournament.update_fixture(f, %{
        is_live: true, live_home_goals: 1, live_away_goals: 0,
        live_minute: "23'", fifa_match_id: "400021502"
      })

    assert %Fixture{is_live: true, live_home_goals: 1, live_minute: "23'", fifa_match_id: "400021502"} = f
  end
end
