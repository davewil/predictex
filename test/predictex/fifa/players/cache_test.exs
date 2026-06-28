defmodule Predictex.Fifa.Players.CacheTest do
  # async: false — the cache is a named singleton with a shared ETS table.
  use ExUnit.Case, async: false

  alias Predictex.Fifa.Players.Cache

  defp ok_source do
    fn ->
      {:ok,
       %{
         players: [
           %{
             "shortName" => "Neymar",
             "position" => 4,
             "stats" => %{"goals" => 2},
             "squadId" => 7,
             "fifaId" => 1
           },
           %{
             "shortName" => "Alisson Becker",
             "position" => 1,
             "stats" => %{"goals" => 0},
             "squadId" => 7,
             "fifaId" => 2
           }
         ],
         squads: [%{"id" => 7, "name" => "Brazil", "abbr" => "BRA"}]
       }}
    end
  end

  setup do
    # Cache is started by the app (warm disabled in test); it's a shared named singleton, so
    # clear its ETS table before each case to isolate state (no cross-test stale-data leakage).
    :ets.delete_all_objects(Predictex.Fifa.Players.Cache)
    Application.put_env(:predictex, :players_source_fun, ok_source())
    on_exit(fn -> Application.delete_env(:predictex, :players_source_fun) end)
    :ok
  end

  test "refresh/0 populates the cache and for_team/1 reads it" do
    assert Cache.refresh() == :ok
    assert Cache.for_team("Brazil") |> Enum.map(& &1.name) == ["Neymar", "Alisson Becker"]
    assert Cache.for_team("Brazil") |> hd() |> Map.get(:fifa_id) == 1
  end

  test "unknown team returns []" do
    Cache.refresh()
    assert Cache.for_team("Narnia") == []
  end

  test "a failing source leaves the cache usable (empty), no crash" do
    Application.put_env(:predictex, :players_source_fun, fn -> {:error, :boom} end)
    assert {:error, :boom} = Cache.refresh()
    assert Cache.for_team("Brazil") == []
    # GenServer still alive:
    assert Process.alive?(Process.whereis(Cache))
  end
end
