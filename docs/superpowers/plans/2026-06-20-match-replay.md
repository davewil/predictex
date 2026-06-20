# Match Replay Implementation Plan (lean)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Plan style:** This is a *lean* plan — it fixes the design decisions, exact interfaces/signatures, test intentions, and landmines. It deliberately does **not** transcribe full function/test bodies; delivery writes the code once (TDD), against the real compiler and tests, following the signatures and behaviour below.

**Goal:** Let any player replay the buzz of a real completed fixture — a read-only, in-process, time-compressed playback of its captured live timeline — driving the existing `/fixtures/:id` UI with zero DB writes.

**Architecture:** Replay is a *view-time strategy* of `FixtureLive`. A pure projection (`Predictex.Replay.frames/1`) turns a match's captured `/detail` bodies into ordered score-frames; a shared immutable ETS cache (`Predictex.Replay.Cache`) loads each match's timeline once for all viewers; `FixtureLive` owns a per-process `send_after` cursor that walks the frames, shadowing the fixture's live-state assigns and recomputing the buzz only on score-change frames. Nothing is persisted; the completed fixture row is untouched.

**Tech Stack:** Elixir 1.20 / OTP 28, Phoenix LiveView 1.8, Ecto/Postgres, ETS, FunWithFlags (Ecto-persisted feature flags).

## Global Constraints

- Always run mix via mise: `mise exec -- mix …` (plain `mix` is the wrong version).
- The gate is `mix precommit` (compile --warnings-as-errors, deps.unlock --check-unused, format --check-formatted, credo --strict, test). It runs on every commit that stages `*.ex`/`*.exs` via lefthook. Never `--no-verify`.
- TDD: one failing test → minimal code → green → commit. One vertical slice at a time; no horizontal slicing.
- **No DB writes anywhere in the replay path.** The completed fixture row stays `:completed` with its real final score.
- Reuse the shared decoder `Predictex.LiveScore.attrs_from_body/2` — do not re-implement FIFA body decoding.
- Feature flag `:match_replay` (FunWithFlags). Off by default; **no admin-role gate**. No config registration needed — a flag is implicitly off until enabled at `/admin/feature-flags`.
- Commit autonomously when green; do NOT push or tag (the user's explicit call).

## File Structure

- Create `lib/predictex/replay.ex` — pure `frames/1` (Task 1).
- Create `lib/predictex/replay/cache.ex` — ETS-backed shared cache GenServer (Task 2).
- Modify `lib/predictex/application.ex` — start the cache, config-gated (Task 2).
- Modify `config/test.exs` — gate the cache out of the test tree (Task 2).
- Modify `lib/predictex_web/live/fixture_live.ex` — replay mode (Task 3).
- Create `test/predictex/replay_test.exs` (Task 1); `test/predictex/replay/cache_test.exs` (Task 2); modify `test/predictex_web/live/fixture_live_test.exs` (Task 3).

---

## Task 1: `Predictex.Replay.frames/1` — pure projection

**Files:** create `lib/predictex/replay.ex`; test `test/predictex/replay_test.exs`.

**Interface (produces):**
```
Replay.frames(match_id :: String.t()) ::
  [%{is_live: boolean, live_home_goals: integer | nil,
     live_away_goals: integer | nil, live_minute: String.t() | nil}]
```
Ordered by `captured_at` asc; `[]` when the match has no detail captures.

**Consumes:** `Capture.list_snapshots/1` (Snapshots ordered by `captured_at` asc, with `.endpoint`, `.body`); `LiveScore.attrs_from_body/2` (2nd arg supplies `.live_home_goals`/`.live_away_goals` for the nil-score fallback).

**Behaviour:**
- Filter to `endpoint == "detail"` with a map body; map each body through `LiveScore.attrs_from_body/2`.
- **Nil-score carry-forward:** decode each frame against the *previous decoded frame* (use `Enum.map_reduce/3` with the prior `attrs` as accumulator; seed `%{live_home_goals: 0, live_away_goals: 0}`). A mid-stream body with nil scores must inherit the last known score, matching the live worker (which re-reads the fixture each poll).

**Tests (`async: true`, `DataCase`):** seed synthetic detail snapshots via `Capture.record_snapshot/1` (required keys: `captured_at, endpoint, url, match_id`; include `http_status, body`).
- decodes detail bodies in `captured_at` order and skips non-`detail` snapshots (insert out of time order + one `"now"` snapshot; assert returned order + the `"now"` body absent).
- carries the previous score forward when a later body has nil scores (frame 1 = 2-1, frame 2 = minute only → frame 2 still 2-1).
- returns `[]` for a match with no captures.

**Commit:** `feat(replay): pure frames/1 projection over captured detail timeline (predictex-i1s)`

---

## Task 2: `Predictex.Replay.Cache` — shared immutable ETS cache

**Files:** create `lib/predictex/replay/cache.ex`; modify `lib/predictex/application.ex`, `config/test.exs`; test `test/predictex/replay/cache_test.exs`.

**Interface (produces):**
```
Replay.Cache.start_link(opts) :: GenServer.on_start   # name: __MODULE__
Replay.Cache.frames(match_id :: String.t()) :: [frame]   # same frame shape as Task 1
```

**Consumes:** `Replay.frames/1` (Task 1).

**Behaviour / design:**
- GenServer owns a `:named_table, :public, :set, read_concurrency: true` ETS table created in `init/1`.
- **Reads are direct `:ets.lookup` in the *calling* process** (lock-free, parallel). The GenServer only owns the table.
- **Miss is funneled through the owner** via `GenServer.call({:load, match_id})`, which re-checks the table (guard against a thundering-herd double-load), else computes `Replay.frames/1`, inserts, returns. Empty results (`[]`) are cached too.
- **No invalidation** — capture timelines for completed fixtures are immutable. This is why the cache is safe.

**App wiring (gated like the capture subscribers):**
- `application.ex`: append `replay_cache()` to `children`; helper returns `[Predictex.Replay.Cache]` when `Application.get_env(:predictex, :start_replay_cache, true)`, else `[]`.
- `config/test.exs`: `config :predictex, start_replay_cache: false` (tests start it per-test via `start_supervised!/1` so each gets a fresh table — no cross-test leakage and no app-owned process reading the DB outside the sandbox).

**Tests (`async: false`, `DataCase`, `start_supervised!(Replay.Cache)` in setup):**
- `frames/1` returns the projected frames on a miss and **caches** them — prove caching by deleting all `Capture.Snapshot` rows after the first call and asserting the second call returns the same frames.
- `frames/1` returns `[]` for a match with no captures.

**Commit:** `feat(replay): shared immutable ETS frame cache (predictex-i1s)`

---

## Task 3: `FixtureLive` replay mode

**Files:** modify `lib/predictex_web/live/fixture_live.ex`; test `test/predictex_web/live/fixture_live_test.exs`.

**Interface (produces):**
- New assigns: `@view_fixture` (the real fixture, or a live-shadow during replay), `@replay` (`nil` or `%{frames, index, interval_ms, h, a, timer}`), `@replay_available?`.
- Events: `"start_replay"`, `"stop_replay"`, `"restart_replay"`.
- `handle_info(:replay_tick, socket)`.

**Consumes:** `Replay.Cache.frames/1`; `FunWithFlags.enabled?(:match_replay)`; existing `Buzz.scenarios_with_deltas/3`, `Buzz.headlines/4`.

**Behaviour / design:**
- `replay_available?(fixture)` = `FunWithFlags.enabled?(:match_replay) and fixture.status == :completed and not is_nil(fixture.fifa_match_id) and Replay.Cache.frames(fixture.fifa_match_id) != []`. The `and` chain short-circuits, so the cache is touched **only** when the flag is on (this is what keeps unrelated tests off the cache path — see landmine 2).
- `load_all/2` additionally assigns `@view_fixture = fixture`, `@replay = nil`, `@replay_available? = replay_available?(fixture)`.
- **Cursor.** `start_replay` sets `@replay` (index 0, `interval_ms` default 1000, `h: nil, a: nil`) and calls `advance/1`. `advance/1` applies the frame at the current index, then schedules the next `:replay_tick` (storing the timer ref) and bumps the index — **except at the end** (see terminal decision). `handle_info(:replay_tick, …)` calls `advance/1`. A `replay: nil` guard clause on both `advance/1` and `:replay_tick` no-ops stray ticks.
- **Terminal-frame decision (ACCEPTED): stay on the final frame.** When the last frame is applied, **stop scheduling but leave it displayed** — `@replay` stays non-nil with `timer: nil` (so the Stop/Restart controls remain and the climactic live frame is the rendered state). Revert to the recap **only** on `"stop_replay"` (or `"restart_replay"`, which stops then starts). Do **not** auto-revert to recap in the terminal tick.
- **`apply_frame` (the shadow + Gap A + Gap B#1):**
  - Build `@view_fixture = struct(@fixture, %{is_live: true, live_home_goals: …, live_away_goals: …, live_minute: …})` (in-memory only).
  - Force `@recap? = false` — **Gap A**: the fixture is `:completed`, so the recap (final score, Goals, per-pick `+points`) is gated on `status`, not `is_live`; without this the climbing buzz renders next to the final score + breakdown, spoiling the suspense.
  - **Gap B#1**: recompute `@scenarios`/`@headlines` only when the frame's `(h, a)` differs from `@replay.h/@replay.a` (each `scenarios_with_deltas/3` runs `Standings.project/3` ×3 = a full re-rank; minute-only frames just refresh `@view_fixture`).
- `stop_replay` cancels the timer and calls `load_all/2` on the real fixture (restores recap/static view, `@replay = nil`, `@view_fixture = fixture`).
- **Live-update guard:** add a `handle_info({:live_update, _}, socket)` clause that no-ops when `@replay != nil` (a producer never writes a completed fixture, but never let it disturb a replay). The existing non-replay clause must also keep `@view_fixture` in step with `@fixture` on the minute-only branch (assign both).
- **Template:**
  - Switch the match-header live/score/minute/kickoff reads from `@fixture` to `@view_fixture` (team names/identity stay `@fixture`; normal mode `@view_fixture == @fixture`, so no behaviour change for live/upcoming/recap fixtures).
  - Add a control block `:if={@replay_available?}`: a "▶ Replay this match" button (`phx-click="start_replay"`) when `@replay == nil`; "↻ Restart" + "■ Stop" when replaying.

**Landmines:**
1. **Round ordinal is validated `1..8`** (`Round` changeset) — test rounds must use an in-range ordinal (per-test sandbox isolation makes a fixed `1` safe). Do **not** use `System.unique_integer` for ordinal.
2. **Gap A only has teeth on a GROUP completed fixture** — `recap?` is `true` only for `status == :completed and stage == :group`. A knockout fixture never shows the recap, so the "hides the recap" assertion would pass trivially. The replay test helper must build a **group** completed fixture.
3. **Flag isolation** — `replay_available?` runs at every mount; a leaked `:match_replay` flag would push unrelated tests onto the (test-gated-out) cache path and crash on the missing ETS table. Mitigated by enabling the flag only inside the replay `describe` with an `on_exit` disable. **Verify this before building the rest of Task 3** (Step 1 below).

- [ ] **Step 1 (verify flag isolation FIRST):** add a `describe "replay mode"` with `setup` doing `FunWithFlags.enable(:match_replay)` + `on_exit(fn -> FunWithFlags.disable(:match_replay) end)`, containing one trivial test, and a **separate top-level** test (outside the describe, so the flag is off) asserting `FunWithFlags.enabled?(:match_replay) == false`. Run the whole file. If the top-level test is green and nothing else crashes, the pattern holds — proceed. If it leaks, the structural fallback is to **not** gate the cache out of the test tree (start it in the app tree for tests too, drop the `start_supervised!` calls) so the table always exists.

- [ ] **Step 2:** implement `replay_available?`, the `load_all` assigns, the events, `:replay_tick`/`advance`/`apply_frame`/`stop_replay`, the live-update guard, and the template changes (per Behaviour above), TDD against the test list below.

**Test list (`ConnCase`, `async: false`; replay tests inside the flag-enabled `describe`; helper builds a settled GROUP fixture with a capture timeline incl. one trailing minute-only frame, e.g. frames `10' 0-0`, `30' 1-0`, `80' 2-1`, `85' 2-1`):**
- **Replay shows live buzz, hides recap (Gap A):** mount a settled group fixture with a capture timeline + a prediction; pre-replay HTML shows the recap (`"Goals"`) and the control (`"Replay this match"`); click start → render shows `LIVE` + frame-0 minute (`10'`) and **no** `"Goals"`. Tick to the end; assert the **final frame stays displayed** (`85'`) and the control now shows Restart/Stop (terminal-stay decision).
- **Minute-only skip (Gap B#1 coverage):** the `85' 2-1` frame follows `80' 2-1` — after reaching it, assert the displayed minute advanced to `85'` while the score stayed `2-1` (exercises the no-recompute branch).
- **No DB write:** after starting + a tick, reload the fixture row; assert `status == :completed`, `is_live == false`, `live_home_goals == nil`, `{home_goals, away_goals} == {2, 1}`.
- **No control without a timeline:** completed group fixture with a `fifa_match_id` but no captures → no `"Replay this match"`.
- **Flag off hides control** (top-level test, flag off): completed fixture with captures → no `"Replay this match"`.
- Drive ticks deterministically with `send(lv.pid, :replay_tick)` (no wall-clock).

**Step 3:** run `mise exec -- mix test test/predictex_web/live/fixture_live_test.exs` then `mise exec -- mix precommit`; expect green.

**Commit:** `feat(replay): FixtureLive replay mode over completed fixtures (predictex-i1s, predictex-cil)`

---

## Task 4: Close out tracking

- `bd note predictex-i1s "Implemented per the 2026-06-20 strategy spec: Replay.frames/1 + Replay.Cache (ETS) + FixtureLive replay mode (flag :match_replay, @view_fixture shadow, recap-off, buzz-on-score-change, stay-on-final-frame). No DB writes. Committed local, unpushed. Deploy: enable :match_replay at /admin/feature-flags."`
- `bd close predictex-cil -r "Folded into i1s: replay is a per-fixture FixtureLive control behind :match_replay, not an admin global toggle."`
- Add a one-line RESUME deploy note: the `:match_replay` flag ships OFF; enable it at `/admin/feature-flags` to turn replay on for all players.

---

## Self-Review

- **Spec coverage:** pure projection (Task 1), shared immutable cache + direct-lookup reads (Task 2), FixtureLive per-process cursor / no DB writes / flag gate / recap suppression (Gap A) / buzz-on-score-change (Gap B#1, now covered by the minute-only frame test) / stay-on-final-frame (Task 3), `cil` reshaped/closed + deploy flag note (Task 4). `Standings.project/3` unchanged (swap-not-add). Out of scope (scrubbing/loop/synchronized/delta-baseline) not built. ✓
- **Type consistency:** frame shape `%{is_live, live_home_goals, live_away_goals, live_minute}` identical across `Replay.frames/1`, `Replay.Cache.frames/1`, `apply_frame`; `@replay` keys `frames, index, interval_ms, h, a, timer` written in `start_replay` and read in `advance`/`apply_frame`. ✓
- **Open verification gate:** Task 3 Step 1 (flag isolation) must pass before the rest of Task 3.
