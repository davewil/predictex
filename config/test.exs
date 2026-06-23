import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :predictex, Predictex.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "predictex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :predictex, PredictexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "bwuDdg3TrBR0plHiO87HRDOU2wCrrFIgr2jfC8lfd4TJDykcC8ug1ovqVNhpY6l4",
  server: false

# In test we don't send emails
config :predictex, Predictex.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :predictex, :league_invite_code, "test-code"

# Oban runs in manual mode in tests — no queues, cron, or plugins fire automatically;
# workers are driven explicitly via Oban.Testing.perform_job/2.
config :predictex, Oban, testing: :manual

# Stub the admin "Sync from feed" source so tests never hit the network (or the DB
# from the start_async task). Real ingestion is covered by Predictex.Results.IngestTest.
config :predictex, :result_sync_fun, fn ->
  %{rounds: 0, fixtures_ok: 0, fixtures_error: 0, source: "stub"}
end

config :predictex, :fifa_fallback_fun, fn -> %{candidates: 0, settled: 0} end

# Knockout-id backfill rounds source stubbed (no network); worker tests override per-test.
config :predictex, :ko_ids_rounds_fun, fn -> {:ok, []} end

# Cohort sync source stubbed in tests (no network); worker tests override per-test.
config :predictex, :cohort_source_fun, fn -> {:ok, %{rounds: [], match_stats: %{}}} end
config :predictex, :fifa_reference_fun, fn -> {:ok, []} end

# LiveScoreSync (predictex-c46) fetch stubbed in tests; worker tests override per-test.
config :predictex, :live_score_fetch_fun, fn _url -> {:ok, 200, %{}} end

# Capture subscribers (predictex-rfm) must NOT auto-start in test — they'd collide on the
# registered name with recorder_test's own start_supervised! and react to unrelated broadcasts.
config :predictex, start_capture_subscribers: false

# Replay cache must NOT auto-start in test — each test starts its own fresh table via
# start_supervised!(Predictex.Replay.Cache) to avoid cross-test leakage.
config :predictex, start_replay_cache: false

# NOTE: do NOT override `:fun_with_flags, :cache` here. FunWithFlags marks that key as a
# compile_env, and CI caches the compiled dep keyed on mix.lock — so a test-only override
# diverges from the cached compile-time value and fails compile-env validation in CI.
# Flag-test isolation is handled in-test instead: enable the flag in a `setup` (the DB
# write rolls back with the sandbox txn) and flush the ETS cache in `on_exit`
# (FunWithFlags.Store.Cache.flush/0 — pure ETS, no DB → no ownership error) so the enabled
# state can't leak into later tests.
