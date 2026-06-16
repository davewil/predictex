# Automated Result Sync (Oban) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the existing idempotent `Results.Ingest.sync_from_url/0` automatically every 15 minutes via an Oban cron worker, so the leaderboard refreshes without anyone clicking "Sync from feed".

**Architecture:** Add Oban (Postgres-backed job queue) as a supervised child. Wire it in with the Pruner plugin first and confirm the suite still boots green (isolating "Oban wired correctly" from worker logic). Then add a `ResultSync` Oban worker, then register it on a `*/15` cron. Unify the admin "Sync from feed" button and the worker on one injectable, test-stubbable sync source so tests never hit the network.

**Tech Stack:** Elixir 1.20 / OTP 28 (via `mise`), Phoenix 1.8, Ecto/Postgres, **Oban ~> 2.19** (new), Req. All `mix` calls are `mise exec -- mix …`.

**Spec:** `docs/superpowers/specs/2026-06-16-result-sync-automation-design.md`

---

## File structure

| File | Responsibility | Action |
|------|----------------|--------|
| `mix.exs` | add `{:oban, "~> 2.19"}` | Modify |
| `priv/repo/migrations/20260616000001_add_oban_jobs_table.exs` | create `oban_jobs` table | Create |
| `config/config.exs` | base Oban config (repo, queues, Pruner) | Modify |
| `config/test.exs` | `Oban` `testing: :manual`; rename sync key | Modify |
| `lib/predictex/application.ex` | add `{Oban, …}` supervised child | Modify |
| `lib/predictex_web/live/admin_fixtures_live.ex` | `:admin_sync_fun` → `:result_sync_fun` | Modify |
| `lib/predictex/workers/result_sync.ex` | the cron worker | Create |
| `test/predictex/workers/result_sync_test.exs` | worker behavior | Create |
| `test/predictex/oban_config_test.exs` | cron entry is registered | Create |

Task order (each leaves the suite green): dep → migration → wire-in (Pruner only) → DRY rename → worker → cron entry → final gate.

---

## Task 1: Add the Oban dependency

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add the dep**

In `mix.exs`, in the `deps/0` list, add after the `{:jason, "~> 1.2"},` line:

```elixir
      {:oban, "~> 2.19"},
```

- [ ] **Step 2: Fetch it**

Run: `mise exec -- mix deps.get`
Expected: resolves and fetches `oban` (and its dep `ecto_sql`/`postgrex` already present). No errors.

- [ ] **Step 3: Confirm it compiles**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "build: add oban dependency (predictex-mt6)"
```

---

## Task 2: Oban jobs migration

**Files:**
- Create: `priv/repo/migrations/20260616000001_add_oban_jobs_table.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260616000001_add_oban_jobs_table.exs`:

```elixir
defmodule Predictex.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)
  end

  # version: 1 ensures a full rollback regardless of the version migrated up to.
  def down do
    Oban.Migration.down(version: 1)
  end
end
```

- [ ] **Step 2: Migrate dev and test databases**

Run:
```bash
mise exec -- mix ecto.migrate
MIX_ENV=test mise exec -- mix ecto.migrate
```
Expected: both apply `AddObanJobsTable` and create `oban_jobs`. No errors.

- [ ] **Step 3: Verify the table exists**

Run: `mise exec -- mix ecto.migrations | tail -3`
Expected: `add_oban_jobs_table` shows as `up`.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/20260616000001_add_oban_jobs_table.exs
git commit -m "feat: oban_jobs migration (predictex-mt6)"
```

---

## Task 3: Wire Oban into the app (Pruner only) — suite boots green

**Files:**
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `lib/predictex/application.ex`

No cron / no worker yet — this isolates "Oban starts cleanly in the tree" from worker logic.

- [ ] **Step 1: Base Oban config**

In `config/config.exs`, add immediately **before** the final `import_config "#{config_env()}.exs"` line:

```elixir
# Oban — background jobs (result sync now; xox import later). Cron entries are added
# alongside their worker modules so Oban's Cron plugin can validate them at boot.
config :predictex, Oban,
  repo: Predictex.Repo,
  queues: [default: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]
```

- [ ] **Step 2: Disable Oban execution in tests**

In `config/test.exs`, add (anywhere after the `import Config` line, e.g. next to the other `config :predictex` lines):

```elixir
# Oban runs in manual mode in tests — no queues, cron, or plugins fire automatically;
# workers are driven explicitly via Oban.Testing.perform_job/2.
config :predictex, Oban, testing: :manual
```

- [ ] **Step 3: Add Oban to the supervision tree**

In `lib/predictex/application.ex`, add `{Oban, Application.fetch_env!(:predictex, Oban)}` to the `children` list, **after** `Predictex.Repo` and before `PredictexWeb.Endpoint`:

```elixir
    children = [
      PredictexWeb.Telemetry,
      Predictex.Repo,
      {Oban, Application.fetch_env!(:predictex, Oban)},
      {DNSCluster, query: Application.get_env(:predictex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Predictex.PubSub},
      PredictexWeb.Endpoint
    ]
```

- [ ] **Step 4: Verify the whole suite still boots green with Oban in the tree**

Run: `mise exec -- mix test`
Expected: PASS (same count as before this task). If Oban fails to start, the boot error appears here — fix before proceeding.

- [ ] **Step 5: Commit**

```bash
git add config/config.exs config/test.exs lib/predictex/application.ex
git commit -m "feat: supervise Oban (Pruner only), manual mode in tests (predictex-mt6)"
```

---

## Task 4: DRY — one injectable sync source (`:result_sync_fun`)

**Files:**
- Modify: `lib/predictex_web/live/admin_fixtures_live.ex`
- Modify: `config/test.exs`

The admin "Sync from feed" button already injects `:admin_sync_fun`. Rename it to
`:result_sync_fun` so the worker (Task 5) shares the exact same hook.

- [ ] **Step 1: Rename in the LiveView**

In `lib/predictex_web/live/admin_fixtures_live.ex`:
- In the `@moduledoc`, change `injectable (\`:admin_sync_fun\`)` to `injectable (\`:result_sync_fun\`)`.
- In `handle_event("sync", …)`, change the line:

```elixir
    sync_fun = Application.get_env(:predictex, :admin_sync_fun, &Ingest.sync_from_url/0)
```
to:
```elixir
    sync_fun = Application.get_env(:predictex, :result_sync_fun, &Ingest.sync_from_url/0)
```

- [ ] **Step 2: Rename the test stub**

In `config/test.exs`, change the existing block:

```elixir
config :predictex, :admin_sync_fun, fn ->
  %{rounds: 0, fixtures_ok: 0, fixtures_error: 0, source: "stub"}
end
```
to:
```elixir
config :predictex, :result_sync_fun, fn ->
  %{rounds: 0, fixtures_ok: 0, fixtures_error: 0, source: "stub"}
end
```

- [ ] **Step 3: Verify the admin fixtures sync test still passes (network-free)**

Run: `mise exec -- mix test test/predictex_web/live/admin_fixtures_live_test.exs`
Expected: PASS (4 tests) — the sync-button test still uses the stub via the new key.

- [ ] **Step 4: Confirm no stale references**

Run: `grep -rn "admin_sync_fun" lib config test`
Expected: no output (all renamed).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex_web/live/admin_fixtures_live.ex config/test.exs
git commit -m "refactor: unify sync source on :result_sync_fun (predictex-mt6)"
```

---

## Task 5: The `ResultSync` worker

**Files:**
- Create: `lib/predictex/workers/result_sync.ex`
- Create: `test/predictex/workers/result_sync_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/predictex/workers/result_sync_test.exs`:

```elixir
defmodule Predictex.Workers.ResultSyncTest do
  use Predictex.DataCase, async: true
  use Oban.Testing, repo: Predictex.Repo

  alias Predictex.Workers.ResultSync

  test "perform returns :ok when the sync source returns a summary" do
    # config/test.exs sets :result_sync_fun to a stub summary map
    assert :ok = perform_job(ResultSync, %{})
  end

  test "perform returns {:error, reason} when the sync source fails (so Oban retries)" do
    Application.put_env(:predictex, :result_sync_fun, fn -> {:error, :boom} end)
    on_exit(fn -> restore_result_sync_fun() end)

    assert {:error, :boom} = perform_job(ResultSync, %{})
  end

  defp restore_result_sync_fun do
    Application.put_env(:predictex, :result_sync_fun, fn ->
      %{rounds: 0, fixtures_ok: 0, fixtures_error: 0, source: "stub"}
    end)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/predictex/workers/result_sync_test.exs`
Expected: FAIL — `Predictex.Workers.ResultSync` is undefined.

- [ ] **Step 3: Implement the worker**

Create `lib/predictex/workers/result_sync.ex`:

```elixir
defmodule Predictex.Workers.ResultSync do
  @moduledoc """
  Oban worker that pulls fresh openfootball results on a schedule (every 15 min, see the
  Cron config). Delegates to the same injectable sync source the admin "Sync from feed"
  button uses (`:result_sync_fun`, default `Results.Ingest.sync_from_url/0`), so tests run
  network-free.

  `sync_from_url/0` returns a summary map on success or `{:error, reason}` on HTTP failure;
  returning the error from `perform/1` lets Oban retry with backoff (`max_attempts: 3`).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Predictex.Results.Ingest

  @impl Oban.Worker
  def perform(_job) do
    case sync_fun().() do
      {:error, reason} ->
        Logger.error("result sync failed: #{inspect(reason)}")
        {:error, reason}

      summary ->
        Logger.info("result sync ok: #{inspect(summary)}")
        :ok
    end
  end

  defp sync_fun do
    Application.get_env(:predictex, :result_sync_fun, &Ingest.sync_from_url/0)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/predictex/workers/result_sync_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/predictex/workers/result_sync.ex test/predictex/workers/result_sync_test.exs
git commit -m "feat: ResultSync Oban worker (predictex-mt6)"
```

---

## Task 6: Register the 15-minute cron entry

**Files:**
- Modify: `config/config.exs`
- Create: `test/predictex/oban_config_test.exs`

Now that the worker module exists, add the Cron plugin pointing at it (Oban's Cron plugin
validates the worker is an `Oban.Worker` at boot, so this must come after Task 5).

- [ ] **Step 1: Write the failing test**

Create `test/predictex/oban_config_test.exs`:

```elixir
defmodule Predictex.ObanConfigTest do
  use ExUnit.Case, async: true

  test "the result sync worker is registered on a 15-minute cron" do
    plugins = Application.fetch_env!(:predictex, Oban)[:plugins]

    {_mod, opts} =
      Enum.find(plugins, fn
        {Oban.Plugins.Cron, _opts} -> true
        _ -> false
      end)

    assert {"*/15 * * * *", Predictex.Workers.ResultSync} in opts[:crontab]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/predictex/oban_config_test.exs`
Expected: FAIL — there is no `Oban.Plugins.Cron` plugin yet (`Enum.find` returns `nil`, the match raises).

- [ ] **Step 3: Add the Cron plugin with the worker**

In `config/config.exs`, update the Oban `plugins:` list to add the Cron plugin:

```elixir
config :predictex, Oban,
  repo: Predictex.Repo,
  queues: [default: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron, crontab: [{"*/15 * * * *", Predictex.Workers.ResultSync}]}
  ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/predictex/oban_config_test.exs`
Expected: PASS.

- [ ] **Step 5: Verify the app still boots with the cron registered**

Run: `mise exec -- mix test`
Expected: full suite PASS (Oban Cron validates `ResultSync` at boot — green confirms the worker is a valid `Oban.Worker`).

- [ ] **Step 6: Commit**

```bash
git add config/config.exs test/predictex/oban_config_test.exs
git commit -m "feat: schedule ResultSync every 15 minutes via Oban Cron (predictex-mt6)"
```

---

## Task 7: Full gate & close-out

- [ ] **Step 1: Run the full quality gate**

```bash
mise exec -- mix test
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix deps.unlock --check-unused
```
Expected: all green. (`deps.unlock --check-unused` confirms `oban` is actually used.)

- [ ] **Step 2: Local boot sanity (optional)**

Run: `mise exec -- mix phx.server`, confirm it boots with no Oban errors in the log, then stop it.
Oban should log queue/plugin startup; the cron fires `ResultSync` on the next `:00/:15/:30/:45`.

- [ ] **Step 3: Close the issue**

```bash
bd close predictex-mt6 --reason="Automated result sync: Oban Cron runs Ingest.sync_from_url/0 every 15 min; max_attempts:3 with backoff; shares :result_sync_fun with the admin button; xox-ready substrate."
```

> Deploy is a separate step (push `main` → tag `vX.Y.Z`) and is the operator's call — the new
> Oban migration runs automatically via the generic `Release.migrate/0` in the deploy pipeline
> (boot-check uses `eval` so it does not start Oban before the table exists).

---

## Self-review notes (author)

- **Spec coverage:** dep (T1), migration `version: 14` (T2), config + Pruner + supervisor child + `testing: :manual` (T3), `:result_sync_fun` DRY (T4), worker with `max_attempts: 3` + error-surfacing (T5), `*/15` cron + registration test (T6), full gate (T7). Deploy-safety and failure-handling (exhaustion → manual button) are documented in the spec; no code needed.
- **Ordering invariant:** the Cron entry (T6) references `Predictex.Workers.ResultSync`, which Oban's Cron plugin validates at boot — so the worker (T5) must exist first. T3 wires Oban with Pruner only so the suite boots green before any worker exists.
- **Network safety:** all worker/admin tests go through the stubbed `:result_sync_fun`; no test hits openfootball.
- **Verify-before-assume:** the `oban_jobs` schema version (`14`) and the `Oban.Migration` / `testing: :manual` / Cron API were confirmed against current Oban docs (Context7).
