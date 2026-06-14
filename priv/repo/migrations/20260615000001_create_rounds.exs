defmodule Predictex.Repo.Migrations.CreateRounds do
  use Ecto.Migration

  def change do
    create table(:rounds) do
      add :name, :string, null: false
      add :stage, :string, null: false
      add :ordinal, :integer, null: false
      add :opens_at, :utc_datetime
      add :opened, :boolean, null: false, default: false

      timestamps()
    end

    create unique_index(:rounds, [:ordinal])
  end
end
