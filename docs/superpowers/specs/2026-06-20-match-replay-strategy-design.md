# Match Replay — Design (v2: view-time strategy)

**Date:** 2026-06-20
**Status:** draft (pre-implementation)
**Supersedes:** `2026-06-17-match-replay-demo-design.md`
**Relates to:** predictex-i1s (engine), predictex-cil (control), predictex-c46 (live buzz),
predictex-rfm (capture pipeline)

## Why this supersedes the 2026-06-17 design

The original design replayed a captured match by **mutating a dedicated demo fixture row**
and broadcasting on its PubSub topic — a single, shared, *synchronized* demo for an audience.
Two problems surface the moment replay becomes a per-**player** affordance:

1. **It doesn't scale to per-player replay.** N players each replaying a match would need N
   fabricated fixture rows, and they would cross-talk on the shared `fixture:<id>` topic
   (everyone sees everyone's playback).
2. **It needed a fabricated match at all** only because, pre-tournament, no *real* completed
   fixture had both a capture timeline and member predictions.

The tournament is now underway: real completed fixtures have real `fifa_captures` timelines
**and** real member predictions. So replay is reframed as a **view-time strategy of
`FixtureLive`** over real completed fixtures — no fabricated rows, no DB writes, per-player
isolation by construction. The entire seeded `Demo` replay-world is dropped.

## Decisions (locked)

- **Target = any real `:completed` fixture that has a capture timeline.** No demo/fabricated
  fixtures.
- **Replay is a strategy of `FixtureLive`.** The source of the *current*
  `(home, away, minute, is_live)` is pluggable: **Live** (DB row, driven by the producer) or
  **Replay** (an in-process cursor over captured frames). Everything downstream — score header,
  minute, `Buzz.scenarios_with_deltas/3`, picks reveal — is identical.
- **No DB writes during replay.** The completed fixture's row is untouched (stays `:completed`
  with its real final score). Replay state is **local to each LiveView process**. This makes
  replay *safe by construction* — it cannot corrupt data or fight `LiveScoreSync` (stronger than
  the old "fenced demo row").
- **Per-player, in-process playback.** Each `FixtureLive` owns its `Process.send_after` cursor.
  10 players = 10 independent cursors, zero shared mutable state.
- **Frames via a pure projection + a shared immutable ETS cache** (load-once, many readers).
- **Feature-flag gated** (FunWithFlags `:match_replay`) — dark-shipped, available to all players
  when on, **no admin gate**.
- **Default cadence 1s/frame** (configurable). Play-once with **restart**. Scrubbing / pause /
  variable-speed / loop are out of scope for v1.

## Correction to a prior assumption (historical standings base)

An earlier worry was that replaying a *completed* fixture would double-count it in the
leaderboard, requiring a "standings as-of-before-this-match" base. **Reading
`Standings.project/3` shows this is a non-issue:** `project/3` **swaps (overrides)** the target
fixture's score in memory and re-ranks — it does not add to the base. So
`project(fixture_id, h, a)` for a completed fixture counts it **once** at the replay score `h-a`,
with every other fixture at its real final. That is exactly the correct buzz for the replay
moment, and `Standings.project/3` / `Buzz.*` work **as-is**, unchanged.

> Optional later polish (not required, changes feel not correctness): measure buzz *deltas*
> against the pre-match baseline (exclude the fixture) rather than the current real-final
> baseline, so deltas grow through the match instead of returning to zero at the real result.

## Components

### 1. Pure projection — `Predictex.Replay`

- `frames(match_id) :: [%{is_live, live_home_goals, live_away_goals, live_minute}]` — the ordered
  `/detail` capture bodies (`Capture.list_snapshots/1`, filtered to `endpoint == "detail"` with a
  map body, already in `captured_at` order) each decoded via `LiveScore.attrs_from_body/2`. Pure,
  timing-free, unit-testable.
- **Nil-score carry-forward:** decode each frame against the *previous decoded frame* so a
  mid-stream nil score inherits the last known score — matching the live worker (which re-reads
  the fixture each poll). The first frame falls back to a zeroed seed.
- **Zero captures → `[]`.** Callers treat `[]` as "not replayable".

### 2. Shared immutable cache — `Predictex.Replay.Cache`

- A thin GenServer owning a `:named_table, :public, read_concurrency: true` ETS table; cache-aside
  `frames(match_id)`: return cached frames, else compute via `Replay.frames/1` and insert.
- **Reads are direct `:ets.lookup` in the calling (`FixtureLive`) process** — the GenServer only
  *creates/owns* the table. A `GenServer.call`-per-read would re-serialize every read through one
  process and negate `read_concurrency`. (A miss may still go through the owner to populate, to
  avoid a thundering-herd double-load; reads on a hit are lock-free and direct.)
- **Safe because capture timelines for completed fixtures are immutable** → no invalidation logic
  (the hardest part of caching simply doesn't exist here).
- Each `FixtureLive` reads the frame at its **current index** (O(1)); the full timeline lives
  **once** in ETS while each process holds one small frame at a time → **O(timeline)** total
  memory, not O(timeline × players). `read_concurrency: true` → lock-free parallel reads.
- Supervised (owner in the app tree, gated out of tests like the capture subscribers) so the
  cache outlives any single viewer.

### 3. `FixtureLive` replay mode

- A **"Replay this match"** control, shown on a `:completed` fixture that has frames, **behind the
  `:match_replay` flag**. Absent when the fixture has no captures (e.g. England v Croatia,
  `400021507`, 0 rows) — render nothing, or a quiet "no live timeline recorded" note.
- **On start:** resolve `match_id` from `fixture.fifa_match_id`; get the frame count from the
  cache; init cursor `index: 0`; `Process.send_after(self(), :replay_tick, interval_ms)`.
- **On `:replay_tick`:** read `frame[index]` from the cache → set **local** assigns
  (`replay_*` shadowing `@fixture.*`); advance `index`; reschedule until exhausted. **No DB
  writes, no broadcast.**
- **Recompute buzz only on score-change frames** (perf — this is the hot path). Most frames are
  minute-only; `Buzz.scenarios_with_deltas/3` calls `Standings.project/3` **3×** and each
  `project` does `Repo.all(fixtures)` + `Repo.all(players preload predictions)` + a full re-rank.
  A match has ~3–6 goals, so recomputing scenarios only when `(h, a)` changes turns hundreds of
  per-tick recomputes into a handful. `FixtureLive` already has exactly this seam — the
  "minute-only tick advances the displayed minute without recomputing scenarios" path — reuse it.
  (Optional further win: load ranking inputs once per replay session, since they are static while
  replaying a completed match, and pass them into a `project` variant.)
- **Replay mode must render the page *as-if-live*, not as a recap.** The fixture is `:completed`,
  so the existing recap UI is gated on `status`/`recap?`, **not** on `@fixture.is_live`
  (`fixture_live.ex`: `recap? = status == :completed and …` line 55; per-pick `+points`
  `:if={@recap?}` line 211; Goals section `:if={@recap?}` line 221; header score reads
  `@fixture.is_live` line 112). Left unchanged, a replay would show the climbing 0-0→1-0 buzz
  next to the **final** score, the goal breakdown, and awarded points — spoiling the very
  suspense the feature exists for. So the seam is more than `current_score/1`: **in replay mode,
  force `recap?`/`points`/`goals` OFF and enable the `is_live`-gated scenario block.** Practically:
  an `@replay?` assign that (a) overrides the header/minute/score via the picker helpers and
  (b) gates the recap sections to `@recap? and not @replay?` while the scenario block renders
  under `is_live? or @replay?`.
- **Restart** re-arms at `index: 0`. Leaving replay mode / unmount clears the replay assigns.
- **Render seam:** picker helpers (`current_score/1`, `is_live?/1`, `minute/1`) resolve replay-or-real,
  and the `@replay?` flag flips recap-off / live-on as above. Keeps both strategies out of the template.

### 4. Feature flag

- A FunWithFlags flag `:match_replay` gates the control. Off by default; flipped at
  `/admin/feature-flags` (the retained dark-ship dashboard). No new admin UI.

### `predictex-cil` reshaped

`cil` was "admin global Start/Stop demo replay button" (made sense for the shared-broadcast demo).
In this model replay is per-player and initiated from the fixture page, so `cil` **folds into this
design** as the per-fixture `FixtureLive` control behind the `:match_replay` flag. Close/relabel
`cil` accordingly — there is no separate admin toggle to build.

## Data flow

```
completed fixture (real predictions) + fifa_captures(match_id)   ← immutable event log
  └─ Replay.frames(match_id): detail bodies → LiveScore.attrs_from_body (nil carry-forward)
       └─ Replay.Cache (ETS: load-once, shared, concurrent reads)
            └─ FixtureLive (per player): send_after cursor → LOCAL replay assigns
                 └─ Buzz.scenarios_with_deltas(fixture_id, h, a)   [Standings.project swap]
                      └─ render — that player's view only; no DB write, no broadcast
```

## Safety / isolation

- **No writes at all** → cannot corrupt the real fixture or collide with `LiveScoreSync`.
- **Per-process state** → players never affect each other; no shared-topic cross-talk.
- **Only `:completed` fixtures with captures** are replayable; the real row stays `:completed`.
- Replay is read-only over immutable history → idempotent and repeatable.

## Testing

- **`Replay.frames/1`** (pure): synthetic `/detail` captures → decoded frames in `captured_at`
  order; non-`detail`/non-map bodies skipped; nil-score carry-forward; zero rows → `[]`.
- **`Replay.Cache`**: cache-aside (miss computes + inserts; hit returns the same without
  recompute); concurrent reads; immutability (no invalidation path).
- **`FixtureLive` replay mode** (LiveView test): drive replay (tiny `interval_ms`, or send
  `:replay_tick` directly) → local score/minute advance and buzz recomputes; **reload the fixture
  row and assert it is untouched** (no DB write); **replaying a completed fixture hides the recap —
  no final score / no Goals section / no `+points` — and shows the live scenario buzz instead**
  (Gap A regression); buzz recomputes only on score-change frames, not minute-only ones; flag off
  → no control; completed-but-no-captures → no control; restart re-arms at frame 0.
- **`Standings.project/3` / `Buzz.*`**: unchanged — existing tests are the regression.

## Out of scope (follow-ups)

- Scrubbing / pause-resume / variable speed / loop.
- **Synchronized** "everyone watches together" replay (a shared clock broadcasting tick numbers).
- Pre-match delta baseline polish (deltas vs before-the-match rather than real-final).
- ETS sizing/eviction (timelines are small — a few hundred frames; revisit only if memory matters).
