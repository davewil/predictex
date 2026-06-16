defmodule Predictex.Fifa.CrosswalkTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.Crosswalk
  alias Predictex.Tournament.Fixture

  defp fixture(id, team1, team2, kickoff),
    do: %Fixture{id: id, team1: team1, team2: team2, kickoff_at: kickoff, round_id: 1}

  test "match_key reduces an offset ISO date + team pair to {utc_date, unordered set}" do
    key = Crosswalk.match_key("2026-06-11T20:00:00+01:00", "Mexico", "South Africa")
    assert key == {~D[2026-06-11], MapSet.new(["mexico", "south africa"])}
  end

  test "match_key is order-independent on the team pair" do
    assert Crosswalk.match_key("2026-06-11T20:00:00+01:00", "Mexico", "South Africa") ==
             Crosswalk.match_key("2026-06-11T20:00:00+01:00", "South Africa", "Mexico")
  end

  test "match_key applies the FIFA->openfootball alias table" do
    fifa = Crosswalk.match_key("2026-06-15T18:00:00Z", "Korea Republic", "Czechia")
    ours = Crosswalk.match_key("2026-06-15T18:00:00Z", "South Korea", "Czech Republic")
    assert fifa == ours
  end

  test "index_fixtures keys fixtures by their match_key" do
    fx = fixture(7, "Mexico", "South Africa", ~U[2026-06-11 19:00:00Z])
    index = Crosswalk.index_fixtures([fx])

    assert Map.get(
             index,
             Crosswalk.match_key("2026-06-11T20:00:00+01:00", "Mexico", "South Africa")
           ) == fx
  end

  test "home_first? is true when FIFA home matches our team1, false (swap) otherwise" do
    assert Crosswalk.home_first?("Mexico", "Mexico")
    assert Crosswalk.home_first?("Korea Republic", "South Korea")
    refute Crosswalk.home_first?("Iran", "Spain")
  end

  test "norm/1 returns empty string for nil" do
    assert Crosswalk.norm(nil) == ""
  end

  test "utc_date/1 returns nil for a malformed ISO string" do
    assert Crosswalk.utc_date("not-a-date") == nil
  end
end
