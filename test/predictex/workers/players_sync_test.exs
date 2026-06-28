defmodule Predictex.Workers.PlayersSyncTest do
  use Predictex.DataCase, async: false
  use Oban.Testing, repo: Predictex.Repo

  alias Predictex.Fifa.Players.Cache
  alias Predictex.Workers.PlayersSync

  test "perform/1 refreshes the cache from the injected source" do
    Application.put_env(:predictex, :players_source_fun, fn ->
      {:ok,
       %{
         players: [
           %{
             "shortName" => "Neymar",
             "position" => 4,
             "stats" => %{"goals" => 2},
             "squadId" => 7,
             "fifaId" => 1
           }
         ],
         squads: [%{"id" => 7, "name" => "Brazil", "abbr" => "BRA"}]
       }}
    end)

    on_exit(fn -> Application.delete_env(:predictex, :players_source_fun) end)

    assert :ok = perform_job(PlayersSync, %{})
    assert Cache.for_team("Brazil") |> Enum.map(& &1.name) == ["Neymar"]
  end
end
