defmodule Mix.Tasks.Predictex.PromoteAdmin do
  @shortdoc "Promote a player to admin by email (dev/test; use Predictex.Release.promote_admin/1 in prod)"
  @moduledoc "Usage: mix predictex.promote_admin <email>"
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run([email]), do: promote(email)
  def run(_), do: Mix.raise("Usage: mix predictex.promote_admin <email>")

  @doc false
  defdelegate promote(email), to: Predictex.Accounts, as: :promote_admin
end
