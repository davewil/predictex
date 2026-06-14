defmodule Predictex.Repo.Migrations.CreateFixtures do
  use Ecto.Migration

  def change do
    create table(:fixtures) do
      add :round_id, references(:rounds, on_delete: :restrict), null: false
      add :external_ref, :string, null: false
      add :team1, :string, null: false
      add :team2, :string, null: false
      add :group, :string
      add :kickoff_at, :utc_datetime
      add :status, :string, null: false, default: "scheduled"

      # Full-time (regulation) result; nil until completed. ET/penalties are excluded.
      add :home_goals, :integer
      add :away_goals, :integer

      # Derived upstream by the ingestion layer from openfootball goal arrays.
      add :first_scorer_side, :string
      add :first_scorer_player, :string
      add :first_goal_owngoal, :boolean, null: false, default: false

      # FIFA global home/draw/away % for the risky bonus (admin-entered).
      add :cohort_home_pct, :integer
      add :cohort_draw_pct, :integer
      add :cohort_away_pct, :integer

      timestamps()
    end

    create unique_index(:fixtures, [:external_ref])
    create index(:fixtures, [:round_id])
  end
end
