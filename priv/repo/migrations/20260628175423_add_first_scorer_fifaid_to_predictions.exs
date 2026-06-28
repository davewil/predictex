defmodule Predictex.Repo.Migrations.AddFirstScorerFifaidToPredictions do
  use Ecto.Migration

  def change do
    alter table(:predictions) do
      add :first_scorer_fifaid, :integer
    end
  end
end
