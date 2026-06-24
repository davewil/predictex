# Design — `mix predictex.preview_knockout` (dev-only R32 preview)

**Date:** 2026-06-24
**Thread:** `predictex-2ww` (native in-app knockout predictions) — sub-goal (a), "make native KO entry testable now"
**Status:** Approved (advisor-reviewed; user-approved 2026-06-24)

## Problem

Phase 1 of the native knockout game shipped an **editable** `/predictions` entry form
(scoreline + first-team + booster) for the open knockout round. Visibility is gated:

- `Tournament.round_open?(%Round{stage: :knockout, ordinal: o})` is true only when the
  **predecessor round** (`ordinal - 1`) is fully `round_complete?` — every fixture `:completed`
  (`lib/predictex/tournament.ex:45-62`).
- `editable_round?` in `MyPredictionsLive` = `:knockout` **and** `round_open?`
  (`lib/predictex_web/live/my_predictions_live.ex:374-380`).

On 2026-06-24 the group stage is still running, so R32's predecessor (group Round 3) is not
complete → the editable R32 form is **gated invisible until ~28 Jun**. The cutover *logic* is
already CI-proven (regression test, commit `e385da9`: settle → broadcast → `round_open?` flips →
form renders + saves). What is **not** verified is the *rendered* editable form in a real authed
session. The user (also league admin) wants to **click through the real R32 form locally now**,
before match day, rather than discover problems live.

Locked decision (with user): build a **reusable dev-only mix task**. Local eyeball first;
a prod admin-preview control is **deferred** pending the localhost look.

## Why the mechanism is sound (advisor-confirmed)

- **Ordinal structure is stable, not lucky.** `Predictex.Fifa` hard-codes groups as ordinals
  `1..3` and KO as `4..8` (`lib/predictex/fifa.ex`), and `Round` validates `ordinal ∈ 1..8`.
  The first KO round is always ordinal 4; its predecessor is always group Round 3. The
  "lowest-KO → predecessor" lookup cannot drift.
- **Lock does not interfere.** `Predictions.locked?/2` is purely kickoff-vs-now and enforced
  **at save**, not by hiding inputs. R32 kickoffs are future on 24 Jun, so every input renders
  editable and saves. Preview is also display-only-safe: `save_round_predictions/4` rejects
  out-of-round (`:unknown`) and locked (`:locked`) rows server-side.
- **Honest write path.** The task settles via `Tournament.update_fixture/2` →
  `Fixture.changeset` (`@castable` includes `status/home_goals/away_goals`) — the same context
  function the admin "save_result" UI uses (`admin_fixtures_live.ex:38,62-72`). The task skips
  only the `AdminWriteResult` LiveView shell (flash/reload), not any domain validation. No
  hand-stamped `:completed`.

## Design

### Component: `Mix.Tasks.Predictex.PreviewKnockout`

File: `lib/mix/tasks/predictex.preview_knockout.ex`.

- `@shortdoc` + `@moduledoc` (includes the placeholder-team caveat and offline-reversal note).
- `run/1`:
  1. **Env guard first** — `Mix.raise` if `Mix.env() == :prod`, *before* booting anything
     (fail fast, no Repo boot). Belt-and-braces: mix tasks are also not shipped in the release.
  2. `Mix.Task.run("app.start")` — boot the Repo *after* the guard. (Explicit ordering is
     chosen over `@requirements ["app.start"]` precisely so the guard precedes the boot;
     `@requirements` would run `app.start` before `run/1`. The testability goal is unaffected —
     the core below stays `app.start`-free and directly callable.)
  3. Call `open_first_knockout_round/0`.
  4. Print the result: round settled, "R32 now OPEN", `http://localhost:4000/predictions`,
     a login reminder, and the **placeholder-team caveat**.
- `open_first_knockout_round/0` (the testable core — no IO, no `app.start`):
  - Find the lowest-ordinal `:knockout` round. If none → `Mix.raise` (clear "run `mix ecto.reset`").
  - Find its predecessor via `get_round_by_ordinal(ordinal - 1)`. If `nil` → `Mix.raise` (clear).
  - For each predecessor fixture **not already** `:completed`, settle with a deterministic 1–0
    via `Tournament.update_fixture(f, %{home_goals: 1, away_goals: 0, status: :completed})`.
  - `Tournament.broadcast_change/0` so any already-open `/predictions` session re-pulls (mirrors
    real ingest; a harmless no-op for the cold-start eyeball).
  - Return `{:ok, %{round: ko_round, settled_count: n, already_complete: n == 0}}`.

**Properties:**
- **Idempotent** — skips already-completed fixtures; a second run returns `settled_count: 0`.
- **Reversible** — `mix ecto.reset` (offline: `WORLDCUP_JSON=… mix ecto.reset`, since seeds do a
  live `Ingest.sync_from_url()` fetch otherwise). No per-fixture un-settle (acceptable for a dev task).
- **Extensible** — a `--round N` flag could target a later KO round later; YAGNI now (defaults to first KO).

### What the preview shows (scope-setting)

R32 fixtures carry openfootball **placeholder team names** ("Winner Group A" v "Runner-up
Group B") until the bracket resolves — that is exactly why the `source_num` re-key machinery
exists (`ingest.ex`). So this previews the **form mechanics and layout**, not real
matchups/flags. Stated in both the printed output and the moduledoc.

### Side-effects (called out)

The settled fixtures are real completed group results in the **dev** DB — they feed dev
standings/scoring with synthetic 1–0s. That is the point (it exercises the genuine
`round_open? → round_complete?` chain) and is dev-only and resettable. The user is eyeballing
the **R32 form**, not the group table, so the synthetic standings do not confuse the eyeball.

## Testing

`test/mix/tasks/predictex_preview_knockout_test.exs`:
- Seed a tournament: a group round (incomplete) + a KO round whose predecessor is that group
  round. Insert rounds **ascending by `:ordinal`** (the documented deadlock invariant in
  `DataCase.setup_sandbox`).
- Assert `round_open?(ko)` is `false`.
- Call `open_first_knockout_round/0`; assert `{:ok, %{settled_count: n}}` with `n > 0` and that
  `round_open?(ko)` flips `true`.
- Assert **idempotency**: a second call returns `settled_count: 0` and `round_open?` stays `true`.
- Assert the settle is honest: predecessor fixtures are `:completed` with non-nil goals.

This mirrors the CI cutover invariant (`e385da9`) at the seed boundary.

## Prerequisites (mechanical, fresh machine)

1. Disposable Docker Postgres on `localhost:5432` (postgres/postgres — matches `config/dev.exs`):
   `docker run -d --name predictex-dev-pg -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:17-alpine`
   (`docker rm -f predictex-dev-pg` to discard.)
2. `mise exec -- mix ecto.setup` (create + migrate + seed). **Assumption to verify:** seeds
   populate the group + KO rounds/fixtures. If seeds are partial, the task fails loud (Rec 2).
3. `mise exec -- mix predictex.preview_knockout`.
4. `mise exec -- mix phx.server` → log in → `/predictions` → select the R32 tab.

## Deferred alternative (captured per "log the deferred option's requirements")

**Option B — `WORLDCUP_JSON` feed snapshot with the group stage already completed.** Honest,
deterministic, zero dev-standings pollution; reuses the exact same `Ingest` path. Requires
authoring/maintaining a feed fixture file with all group matches `:completed`. Worth promoting
only if the synthetic 1–0 dev standings become a nuisance, or if a fully offline/deterministic
reset is wanted. **Option C** (relaxing the gate for dev via env/flag) was **rejected** by the
advisor as dishonest — it would test a code path that does not exist in prod.

## Out of scope

- Prod admin-preview control (deferred — decide after the localhost eyeball).
- `--round N` targeting of later KO rounds.
- Any change to the gate logic itself (`round_open?`/`round_complete?` unchanged).
