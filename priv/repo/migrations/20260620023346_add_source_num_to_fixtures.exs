defmodule Predictex.Repo.Migrations.AddSourceNumToFixtures do
  use Ecto.Migration

  # openfootball's stable match number (knockout matches 73-104; group matches have none).
  # The stable identity that lets a knockout fixture's teams resolve in place instead of the
  # external_ref changing and the upsert inserting a duplicate (predictex-g8m).
  #
  # Nullable: only knockout fixtures carry a num. The unique index permits many NULL rows
  # (Postgres treats NULLs as distinct), so group fixtures coexist freely.
  def change do
    alter table(:fixtures) do
      add :source_num, :integer
    end

    create unique_index(:fixtures, [:source_num])
  end
end
