defmodule Predictex.Accounts do
  @moduledoc "Context for league participants (players)."

  alias Predictex.Repo
  alias Predictex.Accounts.Player

  def list_players, do: Repo.all(Player)

  def get_player!(id), do: Repo.get!(Player, id)

  def create_player(attrs) do
    %Player{} |> Player.changeset(attrs) |> Repo.insert()
  end
end
