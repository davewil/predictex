defmodule Predictex.Repo.Migrations.AddLiveFieldsToFixtures do
  use Ecto.Migration

  def change do
    alter table(:fixtures) do
      add :live_home_goals, :integer
      add :live_away_goals, :integer
      add :live_minute, :string
      add :is_live, :boolean, null: false, default: false
      add :fifa_match_id, :string
    end

    create index(:fixtures, [:is_live])
    create index(:fixtures, [:fifa_match_id])
  end
end
