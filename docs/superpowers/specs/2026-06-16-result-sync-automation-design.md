# Automated Result Sync — design spec

**Issue:** `predictex-mt6` · **Date:** 2026-06-16 · **Status:** approved (brainstorm), advisor-reviewed

## Purpose

Today an admin must click "Sync from feed" in `/admin/fixtures` to pull fresh openfootball
results. This automates it: a scheduled background job runs the existing idempotent
`Results.Ingest.sync_from_url/0` every 15 minutes, so the leaderboard updates within ~15 min
of full-time without anyone touching the app.

The mechanism (Oban) is chosen deliberately as the **shared substrate for the next
automation, `predictex-xox`** (the FIFA prediction import that 403s scripted requests and
genuinely needs retries/backoff/persistence). Result sync is the simple first worker on it.

## Decisions (brainstorm)

1. **Oban + Cron**, not a lightweight GenServer or Quantum — a Postgres-backed job queue so
   `xox` later gets retries, backoff, uniqueness, and observability for free.
2. **Every 15 minutes, unconditional** (`*/15 * * * *`). The fetch is idempotent and cheap (a
   raw GitHub JSON GET); no match-window guard.

## Architecture

- **Dependency:** `{:oban, "~> 2.19"}`.
- **Migration:** a standard Ecto migration calling `Oban.Migration.up(version: 14)` /
  `down(version: 1)`. Creates the `oban_jobs` table.
- **Supervision:** `{Oban, Application.fetch_env!(:predictex, Oban)}` added to
  `application.ex` children, after `Repo`, before `Endpoint`. Oban supervises its own queues;
  a job crash is isolated and retried, never touching the web tier.
- **Config (`config.exs`):**
  ```elixir
  config :predictex, Oban,
    repo: Predictex.Repo,
    queues: [default: 10],
    plugins: [
      {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
      {Oban.Plugins.Cron, crontab: [{"*/15 * * * *", Predictex.Workers.ResultSync}]}
    ]
  ```
- **Config (`test.exs`):** `config :predictex, Oban, testing: :manual` — cron/queues don't
  auto-fire in tests; the worker is driven explicitly via `Oban.Testing.perform_job/2`.
- **Worker — `Predictex.Workers.ResultSync`:**
  ```elixir
  use Oban.Worker, queue: :default, max_attempts: 3   # exponential backoff built in

  def perform(_job) do
    case sync_fun().() do
      {:error, reason} -> {:error, reason}   # transient/403 -> Oban retries with backoff
      summary -> Logger.info("result sync: #{inspect(summary)}"); :ok
    end
  end
  ```
  `sync_from_url/0` returns a summary map on success or `{:error, reason}` on HTTP failure, so
  a feed hiccup naturally triggers Oban's retry/backoff.

## DRY: one injectable sync source

`AdminFixturesLive` already injects the sync function via `:admin_sync_fun` (so its test skips
the network). The worker needs the same hook. **Unify both on one config key
`:result_sync_fun`** (default `&Results.Ingest.sync_from_url/0`). The admin "Sync from feed"
button and the cron worker then call the identical, test-stubbable source — one concept, one
knob. (`AdminFixturesLive` and its test are updated to the new key; behaviour unchanged.)

## Deploy / migration safety (verified)

`Release.migrate/0` is generic — `Ecto.Migrator.run(:up, all: true)` — so it picks up the new
Oban migration automatically. The deploy order is **boot-check → migrate → recreate**:
- The **boot-check** runs `bin/predictex eval "IO.puts(:boot_ok)"`. `eval` does **not** start
  the supervision tree, so Oban is never started and never queries `oban_jobs` before the
  table exists — no chicken-and-egg.
- **Migrate** (`eval "Release.migrate()"`) creates `oban_jobs`.
- **Recreate** (`docker compose up --force-recreate`) then boots the full tree, and Oban finds
  its table.

No repeat of the `force_ssl`-in-`runtime.exs` boot failure (v0.1.0/v0.2.0). The `oban_jobs`
migration version is pinned (`version: 14`) so re-runs are no-ops.

## Failure handling (conscious decision)

After `max_attempts: 3`, a job is discarded. The homelab has no Oban Web/alerting, so a
permanently-failing sync goes unnoticed except via a **stale leaderboard**, at which point the
operator falls back to the **manual "Sync from feed" button**. This is accepted for a
15-person league: exhausted jobs log at `error` (Oban's default), and the manual path is the
safety net. (Alerting/Oban Web is out of scope; revisit if it bites.)

## Testing

- `test.exs`: `Oban` `testing: :manual`; `:result_sync_fun` stubbed (no network).
- **Worker** (`Oban.Testing.perform_job/2`): stubbed success summary → `:ok`; stubbed
  `{:error, _}` → `{:error, _}` (proves a failure is surfaced for retry, not swallowed).
- **Cron wiring:** assert the crontab in the resolved Oban config contains the
  `{"*/15 * * * *", ResultSync}` entry (the schedule is actually registered).
- **AdminFixturesLive** sync test updated for the `:result_sync_fun` rename (unchanged
  behaviour, still network-free).
- The full suite must boot with Oban in the tree under the Ecto sandbox + `testing: :manual`.

## Out of scope (YAGNI)

Dedicated `:sync` queue (default suffices; `xox` can add its own), Oban Web dashboard,
match-window guard, configurable interval, alerting. `xox` itself is a separate issue.

## Implementation note (for the plan)

Stage it so the dep + config + migration + supervisor child land and **the suite boots green
before the worker is written** — isolating "Oban wired in correctly" from "worker logic."
