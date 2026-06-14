# Seed the database with the World Cup schedule + results from openfootball.
#
#   mix run priv/repo/seeds.exs                                       # fetch the live 2026 feed
#   WORLDCUP_JSON=path/to/worldcup.json mix run priv/repo/seeds.exs   # use a local file (offline)
#
# Idempotent: re-running upserts rounds/fixtures and preserves admin-entered cohort %.

alias Predictex.Results.Ingest

result =
  case System.get_env("WORLDCUP_JSON") do
    nil ->
      IO.puts("Seeding from the live openfootball 2026 feed…")
      Ingest.sync_from_url()

    path ->
      IO.puts("Seeding from #{path}…")
      Ingest.sync_from_file(path)
  end

IO.inspect(result, label: "ingest")
