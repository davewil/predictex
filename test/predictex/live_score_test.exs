defmodule Predictex.LiveScoreTest do
  use Predictex.DataCase, async: true

  alias Predictex.LiveScore
  alias Predictex.Tournament
  alias Predictex.Tournament.Fixture

  defp fixture(attrs \\ %{}) do
    {:ok, r} = Tournament.create_round(%{name: "R1", stage: :group, ordinal: 1})

    {:ok, f} =
      Tournament.create_fixture(
        Map.merge(
          %{
            external_ref: "x",
            team1: "A",
            team2: "B",
            round_id: r.id,
            kickoff_at: ~U[2026-06-17 17:00:00Z]
          },
          attrs
        )
      )

    f
  end

  test "attrs_from_body/2 decodes a live body (MatchStatus 3, nested score)" do
    f = fixture()

    body = %{
      "MatchStatus" => 3,
      "MatchTime" => "23'",
      "HomeTeam" => %{"Score" => 1},
      "AwayTeam" => %{"Score" => 0}
    }

    assert %{is_live: true, live_home_goals: 1, live_away_goals: 0, live_minute: "23'"} =
             LiveScore.attrs_from_body(body, f)
  end

  test "attrs_from_body/2 marks finished (0) / upcoming (1) as not live" do
    f = fixture()
    assert %{is_live: false} = LiveScore.attrs_from_body(%{"MatchStatus" => 0}, f)
    assert %{is_live: false} = LiveScore.attrs_from_body(%{"MatchStatus" => 1}, f)
  end

  test "attrs_from_body/2 keeps the existing score when the body omits it" do
    f = fixture(%{live_home_goals: 2, live_away_goals: 1})
    body = %{"MatchStatus" => 3, "MatchTime" => "70'"}
    assert %{live_home_goals: 2, live_away_goals: 1} = LiveScore.attrs_from_body(body, f)
  end

  test "apply_to_fixture/2 writes only live_* and broadcasts on change" do
    f = fixture(%{status: :scheduled})
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")
    attrs = %{is_live: true, live_home_goals: 1, live_away_goals: 0, live_minute: "10'"}

    assert :ok = LiveScore.apply_to_fixture(f, attrs)
    assert_received {:live_update, _id}

    reloaded = Tournament.get_fixture!(f.id)
    assert %Fixture{is_live: true, live_home_goals: 1, status: :scheduled} = reloaded
  end

  test "apply_to_fixture/2 does not broadcast when nothing changed" do
    f = fixture(%{is_live: true, live_home_goals: 1, live_away_goals: 0, live_minute: "10'"})
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")
    attrs = %{is_live: true, live_home_goals: 1, live_away_goals: 0, live_minute: "10'"}

    assert :ok = LiveScore.apply_to_fixture(f, attrs)
    refute_received {:live_update, _id}
  end
end
