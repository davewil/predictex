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

# Dev/test convenience account, so `mix ecto.reset` always yields a usable login.
# GUARDED to dev/test: this account has a known password and must NEVER exist in prod.
# (Prod boots via `Predictex.Release.migrate`, not this script, so it won't run there — the
# guard is belt-and-braces against a stray `MIX_ENV=prod mix run priv/repo/seeds.exs`.)
if Mix.env() in [:dev, :test] do
  demo = %{
    email: "demo@predictex.test",
    password: "predictex-demo-1234",
    display_name: "Demo Player"
  }

  case Predictex.Accounts.get_player_by_email(demo.email) do
    nil ->
      case Predictex.Accounts.register_player(demo) do
        {:ok, p} -> IO.puts("Seeded demo player #{p.email} (password: #{demo.password})")
        {:error, cs} -> IO.inspect(cs.errors, label: "demo player seed FAILED")
      end

    _existing ->
      IO.puts("Demo player #{demo.email} already exists — left as-is")
  end
end
