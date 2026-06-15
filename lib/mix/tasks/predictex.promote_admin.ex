defmodule Mix.Tasks.Predictex.PromoteAdmin do
  @shortdoc "Promote a player to admin by email"
  @moduledoc "Usage: mix predictex.promote_admin <email>"
  use Mix.Task

  @requirements ["app.start"]

  alias Predictex.Repo
  alias Predictex.Accounts.Player

  @impl Mix.Task
  def run([email]), do: promote(email)
  def run(_), do: Mix.raise("Usage: mix predictex.promote_admin <email>")

  @doc false
  def promote(email) do
    case Repo.get_by(Player, email: email) do
      nil -> raise "No player with email #{email}"
      player -> player |> Ecto.Changeset.change(is_admin: true) |> Repo.update!()
    end
  end
end
