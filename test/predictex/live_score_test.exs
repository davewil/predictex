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

  test "attrs_from_body/2 keeps a suspended match (MatchStatus 11) live" do
    # France v Iraq 2026-06-22: FIFA reported MatchStatus 11 during a ~2h weather break.
    # Only 0/1 are not-live, so any suspension/interruption code stays live — that is what
    # keeps capture alive through a break (predictex-ius). Do NOT narrow this to `== 3`.
    f = fixture()
    assert %{is_live: true} = LiveScore.attrs_from_body(%{"MatchStatus" => 11}, f)
  end

  test "attrs_from_body/2 keeps the existing score when the body omits it" do
    f = fixture(%{live_home_goals: 2, live_away_goals: 1})
    body = %{"MatchStatus" => 3, "MatchTime" => "70'"}
    assert %{live_home_goals: 2, live_away_goals: 1} = LiveScore.attrs_from_body(body, f)
  end

  test "attrs_from_body/2 keeps a genuine 0-0 score (Score: 0 is not falsy-dropped)" do
    f = fixture(%{live_home_goals: 2, live_away_goals: 1})

    body = %{
      "MatchStatus" => 3,
      "MatchTime" => "5'",
      "HomeTeam" => %{"Score" => 0},
      "AwayTeam" => %{"Score" => 0}
    }

    assert %{live_home_goals: 0, live_away_goals: 0} = LiveScore.attrs_from_body(body, f)
  end

  test "attrs_from_body/2 tolerates a non-map team object (schema drift), keeping the existing score" do
    # FIFA schema drift: a team arriving as a scalar (or any non-`%{\"Score\" => _}` shape)
    # instead of a nested score object must decode to the existing-score fallback, NOT raise.
    # Pre-bl8 `get_in(body, [\"HomeTeam\", \"Score\"])` raised on a scalar, and the Updater's
    # bare rescue swallowed it; the decode is now total so a malformed body can't crash the
    # subscriber (predictex-bl8).
    f = fixture(%{live_home_goals: 2, live_away_goals: 1})

    body = %{
      "MatchStatus" => 3,
      "MatchTime" => "30'",
      "HomeTeam" => "Brazil",
      "AwayTeam" => nil
    }

    assert %{is_live: true, live_home_goals: 2, live_away_goals: 1, live_minute: "30'"} =
             LiveScore.attrs_from_body(body, f)
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

    # The per-fixture {:live_update} and the coarse :fixtures_changed (predictex-9p0) share the
    # same `changed?` gate, so this per-fixture refute also proves neither fired. (We avoid a
    # `refute_received :fixtures_changed` here: that topic is global, so a concurrent async test's
    # legitimate broadcast could land in this mailbox and flake the refute.)
    assert :ok = LiveScore.apply_to_fixture(f, attrs)
    refute_received {:live_update, _id}
  end

  test "apply_to_fixture/2 also emits the coarse fixtures-changed signal on change (predictex-9p0)" do
    f = fixture(%{status: :scheduled})
    Tournament.subscribe_changes()
    attrs = %{is_live: true, live_home_goals: 1, live_away_goals: 0, live_minute: "10'"}

    assert :ok = LiveScore.apply_to_fixture(f, attrs)
    assert_received :fixtures_changed
  end

  test "clear_live/1 clears is_live, keeps the last score, and broadcasts" do
    f = fixture(%{is_live: true, live_home_goals: 2, live_away_goals: 1, live_minute: "90'"})
    Phoenix.PubSub.subscribe(Predictex.PubSub, "fixture:#{f.id}")
    Tournament.subscribe_changes()

    assert :ok = LiveScore.clear_live(f)
    assert_received {:live_update, _id}
    # clear_live/1 delegates to apply_to_fixture/2, so it also drives the dashboard feed (9p0).
    assert_received :fixtures_changed

    reloaded = Tournament.get_fixture!(f.id)

    assert %Fixture{is_live: false, live_home_goals: 2, live_away_goals: 1, live_minute: "90'"} =
             reloaded
  end
end
