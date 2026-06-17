# Match Replay / Buzz Demo — Design

**Date:** 2026-06-17
**Status:** approved (pre-implementation)
**Relates to:** predictex-c46 (Live Match Buzz), predictex-70h (FIFA capture spike)

## Context

`Workers.FifaLiveCapture` already records a live match as an append-only stream of
FIFA JSON snapshots in `fifa_captures` (`captured_at`, `match_id`, `endpoint`,
`http_status`, `body`, `error`). Tonight's Portugal v DR Congo (`match_id 400021502`)
banked **696 rows** (348 `detail` + 348 `now`), 0 errors, spanning the full match
(`Spike.summary/1` verified: status arc 1→3→0, goals at 6' and 45'+5').

The buzz drill-down (`/fixtures/:id`) only comes alive during a real live match, and
the pollers must be armed by hand and stop between matches. We want to **replay a
captured match on demand** — time-compressed (default **1s** per tick vs the real
~30s) — so the buzz feature can be demoed to an audience and tested any time, without
waiting for a real fixture. The captured stream is the event source; replay re-emits it.

## Decisions (locked)

- **Target = an isolated demo world** (option A). Replay writes ONLY to a dedicated
  demo fixture, never a real one — so it is safe to run on prod at any time, even
  during a real match, and is fully repeatable.
- **rpc-first** (option C). Ship the engine driven by `Predictex.Replay.start/stop`;
  a one-tap admin button is a documented fast-follow, NOT built in this spec.
- **Reuse, don't duplicate.** The "FIFA `body` → `live_*` attrs + change-detection +
  PubSub broadcast" logic is extracted from `LiveScoreSync` into a shared module so the
  real worker and the replay engine cannot drift.
- Default replay cadence **1s**, configurable; optional **loop** for a continuous demo.

## Components

### 1. Demo world (extend `Predictex.Demo`)

- A **demo round** (e.g. name `"DEMO"`, its own ordinal) and **one demo fixture** that
  mirrors the capture's teams (`"Portugal"` v `"DR Congo"`) with `kickoff_at` set in the
  **past** (so `Predictions.locked?/2` is true → picks are revealed during the demo) and
  `fifa_match_id` left nil (it is never polled by the real worker).
- `Demo.seed/0` additionally creates this round+fixture; the six `@demo.predictex.local`
  players already predict every fixture with varied scorelines, so the demo fixture has a
  spread of picks → real buzz. `Demo.purge/0` removes it with the rest.
- `Demo.replay_fixture/0` returns the canonical demo fixture (the single legal replay
  target). This is the isolation guarantee: the replay engine resolves its target from
  here, never from caller input, so it is structurally incapable of writing to a real
  fixture.

### 2. Shared live decoder (`Predictex.LiveScore`, new)

Extract from `Workers.LiveScoreSync`:
- `attrs_from_body(body) :: %{is_live, live_home_goals, live_away_goals, live_minute}` —
  decode a FIFA `/detail` body (`MatchStatus not in [0,1]`, nested `HomeTeam/AwayTeam.Score`,
  `MatchTime`), with the nil-score fallback already in the worker.
- `apply_to_fixture(fixture, attrs) :: :ok` — write via `Tournament.update_fixture/2`
  (only `is_live` + `live_*`) and broadcast `{:live_update, id}` on `"fixture:#{id}"` when a
  live value changed (the existing change-detection).

`LiveScoreSync` is refactored to call these; its behaviour is unchanged (its tests stay
green). This module is the single source of the decode/broadcast contract.

### 3. Replay engine (`Predictex.Replay`, new — lazy stream + host process)

The event-sourced captures ARE the stream; a thin host process consumes it on a timer
and performs the broadcast side effect.

- `event_stream(match_id, loop?) :: Enumerable.t` — a lazy `Stream` over the `detail`
  captures for `match_id`, ordered by `captured_at`, each mapped through
  `LiveScore.attrs_from_body/1`. `loop?: true` wraps the source list in `Stream.cycle/1`
  for a continuous demo (infinite stream); `false` is a finite one-pass stream. This is the
  pure, testable projection of the event log.
- **Pacing:** `event_stream |> Stream.zip(Stream.interval(interval_ms))`. `Stream.interval/1`
  emits a tick every `interval_ms`, so zipping makes each event materialise exactly one
  interval apart — no manual scheduler. Default `interval_ms: 1000`.
- **Host:** a supervised `Task` (tracked by a named process so it can be stopped) runs
  `Enum.each(paced_stream, fn {attrs, _} -> LiveScore.apply_to_fixture(demo_fixture, attrs) end)`.
  Each application writes the demo fixture's `live_*` and broadcasts `{:live_update, demo_id}`;
  any open `/fixtures/<demo>` updates itself via the existing PubSub handler.
- `start(opts \\ [])` — opts `match_id` (default `"400021502"`), `interval_ms`
  (default `1000`), `loop?` (default `false`). Resolves the target via
  `Demo.replay_fixture/0` and spawns the host on the paced stream.
- `stop/0` — kill the host and reset the demo fixture to `is_live: false` (clean slate).
- Only one replay runs at a time (named host); `start/1` while running restarts it.

> Why not `Stream.iterate/2` directly: it generates values from a seed function (built for
> infinite generators), whereas we replay a *finite recorded list*. `Stream.cycle` (loop) +
> `Stream.interval` (pacing) is the idiomatic fit — same lazy-stream spirit, right tool.

### 4. Control + audience

- **Now:** `Predictex.Replay.start()` / `Predictex.Replay.stop()` via
  `bin/predictex rpc` on prod (or `iex` locally).
- **Fast-follow (out of scope here):** an admin-only "Start/Stop demo replay" control,
  mounted in the admin area behind `:require_admin` (mirrors the FunWithFlags dashboard).
- Because replay broadcasts on the demo fixture's PubSub topic, multiple viewers of
  `/fixtures/<demo>` all see the same replay simultaneously.

## Data flow

```
fifa_captures (match_id, detail bodies, ordered by captured_at)        ← the event log
  └─ Replay.event_stream:  Stream over bodies |> map(LiveScore.attrs_from_body)
       └─ [Stream.cycle if loop?]  |> Stream.zip(Stream.interval(interval_ms))   ← lazy + paced
            └─ host Task: Enum.each → LiveScore.apply_to_fixture(demo_fixture)
                 └─ writes live_* to the DEMO fixture + broadcast "fixture:#{demo_id}"
                      └─ FixtureLive.handle_info → Buzz/Standings.project → all viewers
```

## Safety / isolation

- Replay target is always `Demo.replay_fixture/0` — a fixture in the demo round. It can
  never write to a real fixture (no caller-supplied fixture id).
- The demo fixture has no `fifa_match_id`, so `LiveScoreSync` never polls it; the two
  systems can't collide.
- Writes are confined to `is_live` + `live_*` (the two-writer rule still holds; scoring is
  untouched — it only ever runs on `:completed` fixtures, which the demo fixture is not).
- `stop/0` always resets the demo fixture, so a demo never leaves stale live state.

## Testing

- **`Predictex.LiveScore`** (the extracted module): unit-test `attrs_from_body/1` (live vs
  finished vs upcoming; nested score; nil-score fallback) and `apply_to_fixture/2`
  (writes only `live_*`, broadcasts only on change).
- **`LiveScoreSync`**: existing tests stay green after the refactor (regression).
- **`Predictex.Replay.event_stream/2`** (pure): with a few synthetic `detail` captures,
  assert the finite stream yields decoded `attrs` in `captured_at` order, and that
  `loop?: true` repeats (take more than the source length). No timing involved — fast.
- **`Predictex.Replay` host** (integration): with a tiny synthetic capture stream and a
  short `interval_ms`, assert it writes successive `live_*` to the demo fixture and
  broadcasts in order; assert `stop/0` resets the fixture; assert it targets only the
  demo fixture.
- **`Predictex.Demo`**: `seed/0` creates the demo round+fixture with past kickoff and picks;
  `purge/0` removes them.

## Out of scope (separate follow-ups)

- **Scheduler / auto-arm** (piece ②): start the real capture + buzz pollers 5–10 min before
  each fixture's `kickoff_at` from the schedule (Oban Cron). Its own spec.
- **Admin replay button** (the fast-follow control above).
- A derived discrete-events table (goal/status events). The raw `fifa_captures` bodies are a
  sufficient event source for replay; deriving typed events is a possible later layer, not
  needed now.
