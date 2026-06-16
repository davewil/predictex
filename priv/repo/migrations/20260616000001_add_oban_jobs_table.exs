defmodule Predictex.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  # No :version pins to the latest schema for the installed Oban (2.23).
  def up do
    Oban.Migration.up()
  end

  # version: 1 ensures a full rollback regardless of the version migrated up to.
  def down do
    Oban.Migration.down(version: 1)
  end
end
