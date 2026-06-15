defmodule Predictex.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :predictex

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Promote a player to admin by email, from a release.

      bin/predictex eval "Predictex.Release.promote_admin(\\"you@example.com\\")"
  """
  def promote_admin(email) do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Predictex.Repo, fn _repo ->
        Predictex.Accounts.promote_admin(email)
      end)

    result
  end

  @doc """
  Ingest the World Cup schedule + results from openfootball, from a release.

      bin/predictex eval "Predictex.Release.sync_results()"
  """
  def sync_results do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Predictex.Repo, fn _repo ->
        Predictex.Results.Ingest.sync_from_url()
      end)

    result
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
