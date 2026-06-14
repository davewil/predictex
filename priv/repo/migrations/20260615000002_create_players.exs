defmodule Predictex.Repo.Migrations.CreatePlayers do
  use Ecto.Migration

  def change do
    create table(:players) do
      add :email, :string
      add :display_name, :string, null: false
      add :is_admin, :boolean, null: false, default: false

      timestamps()
    end

    # Postgres treats NULLs as distinct, so several players may have no email yet.
    create unique_index(:players, [:email])
  end
end
