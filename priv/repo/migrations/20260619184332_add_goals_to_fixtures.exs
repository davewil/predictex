defmodule Predictex.Repo.Migrations.AddGoalsToFixtures do
  use Ecto.Migration

  def change do
    alter table(:fixtures) do
      add :goals, {:array, :map}, default: []
    end
  end
end
