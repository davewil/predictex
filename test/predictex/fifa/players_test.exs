defmodule Predictex.Fifa.PlayersTest do
  use ExUnit.Case, async: true

  alias Predictex.Fifa.Players

  # Two squads incl. a FIFA-side name that diverges from openfootball ("Bosnia and Herzegovina").
  defp squads,
    do: [
      %{"id" => 7, "name" => "Brazil", "abbr" => "BRA"},
      %{"id" => 9, "name" => "Bosnia and Herzegovina", "abbr" => "BIH"}
    ]

  defp players,
    do: [
      %{
        "shortName" => "Matheus Cunha",
        "position" => 4,
        "stats" => %{"goals" => 3},
        "squadId" => 7,
        "fifaId" => 430_609
      },
      %{
        "shortName" => "Alisson Becker",
        "position" => 1,
        "stats" => %{"goals" => 0},
        "squadId" => 7,
        "fifaId" => 100_001
      },
      %{
        "shortName" => "Neymar",
        "position" => 4,
        "stats" => %{"goals" => 3},
        "squadId" => 7,
        "fifaId" => 100_002
      },
      %{
        "shortName" => "Edin Dzeko",
        "position" => 4,
        "stats" => %{"goals" => 1},
        "squadId" => 9,
        "fifaId" => 200_001
      },
      # squad with no name entry — must be dropped, not crash:
      %{
        "shortName" => "Ghost",
        "position" => 3,
        "stats" => %{"goals" => 0},
        "squadId" => 99,
        "fifaId" => 300_001
      }
    ]

  describe "parse/2" do
    test "keys squads by Crosswalk.norm and decodes the shared player shape" do
      map = Players.parse(players(), squads())

      assert Map.has_key?(map, "brazil")
      # FIFA "Bosnia and Herzegovina" normalises to openfootball "bosnia & herzegovina":
      assert Map.has_key?(map, "bosnia & herzegovina")
      refute Map.has_key?(map, "99")

      cunha = map["brazil"] |> Enum.find(&(&1.name == "Matheus Cunha"))
      assert cunha == %{name: "Matheus Cunha", position: "FWD", goals: 3, fifa_id: 430_609}
    end

    test "sorts each squad goals-desc then name-asc" do
      names = Players.parse(players(), squads())["brazil"] |> Enum.map(& &1.name)
      # goals: Cunha 3, Neymar 3 (tie → name asc), Alisson 0
      assert names == ["Matheus Cunha", "Neymar", "Alisson Becker"]
    end

    test "decodes all four position codes" do
      sq = [%{"id" => 1, "name" => "Algeria", "abbr" => "ALG"}]

      ps =
        for {code, label} <- [{1, "GK"}, {2, "DEF"}, {3, "MID"}, {4, "FWD"}] do
          %{
            "shortName" => label,
            "position" => code,
            "stats" => %{"goals" => 0},
            "squadId" => 1,
            "fifaId" => code
          }
        end

      decoded = Players.parse(ps, sq)["algeria"] |> Map.new(&{&1.name, &1.position})
      assert decoded == %{"GK" => "GK", "DEF" => "DEF", "MID" => "MID", "FWD" => "FWD"}
    end
  end

  describe "for_team/2" do
    test "returns the squad for a known team, [] for unknown" do
      map = Players.parse(players(), squads())
      assert Players.for_team(map, "Brazil") |> Enum.map(& &1.name) |> Enum.member?("Neymar")
      # alias-normalised lookup works from either spelling:
      assert Players.for_team(map, "Bosnia & Herzegovina") |> length() == 1
      assert Players.for_team(map, "Narnia") == []
    end
  end
end
