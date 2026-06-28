defmodule Predictex.Repo.Migrations.AddFifaStageIdToFixtures do
  use Ecto.Migration

  # The FIFA live `/detail` endpoint is keyed `/{competition}/{season}/{stage}/{matchId}`, and
  # each knockout round is a distinct `stage`. We persist the per-fixture stage id (parsed from
  # `rounds.json`'s `matchcentreUrl` by Fifa.LiveIds) so LiveScoreSync addresses the right stage.
  # Nullable: group / legacy fixtures default to the group stage in the worker.
  def change do
    alter table(:fixtures) do
      add :fifa_stage_id, :string
    end
  end
end
