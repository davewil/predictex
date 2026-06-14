defmodule Predictex.Repo.Migrations.CreatePredictions do
  use Ecto.Migration

  def change do
    create table(:predictions) do
      add :player_id, references(:players, on_delete: :delete_all), null: false
      add :fixture_id, references(:fixtures, on_delete: :delete_all), null: false
      # Denormalized from the fixture so the one-booster-per-round rule is enforceable.
      add :round_id, references(:rounds, on_delete: :restrict), null: false

      add :home_goals, :integer, null: false
      add :away_goals, :integer, null: false

      # Knockout-only extras (nil for group fixtures).
      add :first_scorer_side, :string
      add :first_scorer_player, :string

      add :booster, :boolean, null: false, default: false

      timestamps()
    end

    # One prediction per player per fixture.
    create unique_index(:predictions, [:player_id, :fixture_id])

    # One 2x booster per player per round — a partial unique index, since the rule
    # spans sibling predictions and a row-level constraint cannot express it.
    create unique_index(:predictions, [:player_id, :round_id],
             where: "booster = true",
             name: :one_booster_per_player_round
           )

    create index(:predictions, [:fixture_id])
  end
end
