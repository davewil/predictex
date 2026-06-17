defmodule Predictex.Repo.Migrations.CreateFifaCaptures do
  use Ecto.Migration

  # SPIKE (predictex-70h): raw capture of FIFA v3 live API responses across a match
  # window, for offline analysis. Throwaway — drop once the live MatchStatus code and
  # real-time score behaviour are confirmed and LiveScoreSync is built.
  def change do
    create table(:fifa_captures) do
      add :captured_at, :utc_datetime_usec, null: false
      add :endpoint, :string, null: false
      add :url, :string, null: false
      add :match_id, :string, null: false
      add :http_status, :integer
      add :body, :map
      add :error, :string
    end

    create index(:fifa_captures, [:match_id, :captured_at])
  end
end
