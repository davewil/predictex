# Live Match Buzz / Live Scores — Design

**Issue:** predictex-c46 (blocked by predictex-70h, the live-feed spike — now resolved).
**Date:** 2026-06-17
**Status:** approved, pre-implementation.

Flag-gated (`:live_buzz`) implementation of the headline social feature: when a fixture
is live, members drill into `/fixtures/:id` to see everyone's locked picks, a projected
"if it ends now" leaderboard, and rank-change scenarios — updating in real time as the
score ticks. "Predict the scores. Win the group chat."

## Decisions (locked)

- **Scope:** full c46 (live scores **and** the buzz drill-down), built foundation-first.
- **Placement:** dedicated `/fixtures/:id` LiveView (own process → trivial PubSub;
  shareable URL fits "win the group chat").
- **Real-time:** PubSub — `LiveScoreSync` broadcasts on score change; open drill-downs
  re-project instantly.
- **Data model:** separate `live_*` columns, NOT `status :live` / `home_goals` (see below).
- **Gating:** `LiveScoreSync` runs **ungated** (benign data we want collected); everything
  **visible** is gated on `FunWithFlags.enabled?(:live_buzz)`.

## The two-writer problem (and the fix)

`Workers.ResultSync` ingests openfootball every 15 min. While a match is live, openfootball
reports it as not-yet-played, so if `LiveScoreSync` wrote `status: :live` + `home_goals`,
`ResultSync` would **reset it to `:scheduled` every 15 minutes**.

**Fix:** `LiveScoreSync` writes additive `live_*` columns and never touches
`status`/`home_goals`/`first_scorer`. openfootball stays the sole authority over the
*final* result (which feeds scoring); FIFA is the source only for the *provisional live*
state. Scoring is unaffected — `Scoring.score/3` only ever runs on `:completed` fixtures.

New migration on `fixtures`:
- `live_home_goals :integer`
- `live_away_goals :integer`
- `live_minute :string`   (FIFA `MatchTime`, e.g. `"23'"`)
- `is_live :boolean, default: false`

## Components

### `Predictex.Workers.LiveScoreSync` (new)
Sibling of `Workers.FifaLiveCapture`: windowed self-reschedule, injectable fetch
(`:live_score_fetch_fun`), Gather → Decide → Act.
- **Live detection via detail endpoint** — the per-match detail endpoint is polled; a
  fixture is considered live iff `MatchStatus not in [0, 1]` (0 = finished, 1 = upcoming).
  This is robust to any unconfirmed live `MatchStatus` codes, since every non-terminal,
  non-upcoming status is treated as in-play. (Detail endpoint also supplies score + minute.)
- **Act:** set `is_live: true`, `live_home_goals`, `live_away_goals`, `live_minute` on the
  matched fixture (crosswalk: FIFA `IdMatch` == `fifaId` in `rounds.json`; or date+team
  via `Fifa.Crosswalk`). On finish (no longer in `/now`): set `is_live: false`, leave the
  last live score; openfootball's `ResultSync` later writes the canonical `:completed`.
- **Broadcast** on change: `Phoenix.PubSub.broadcast(Predictex.PubSub, "fixture:#{id}",
  {:live_update, fixture_id})` and a `"fixtures:live"` topic for the leaderboard card.
- Drive on prod via `rpc "Predictex.Workers.LiveScoreSync.start()"` (same pattern as the
  capture worker). FIFA contract: see beads memory `fifa-v3-live-api-contract`.

### `Predictex.Standings.project/3` (new) + `Predictex.Buzz` (new)
- `project(fixture_id, home, away)` — load players+fixtures, swap the one fixture to
  `%{f | status: :completed, home_goals: home, away_goals: away}` in memory, call the
  existing pure `rank/2`. Booster, risky/cohort bonus, **and** round bonus honoured for
  free. Nothing persisted.
- `Buzz` builds the scenario set `{end_now, home+1, away+1}` from the current live score,
  projects each, diffs vs. the real `leaderboard/0`, and emits rank-change narratives with
  "YOU" framing for the viewing player (`current_scope`).
- Both pure and DB-light; the heavy logic is unit-tested with no LiveView.

### `PredictexWeb.FixtureLive` (new) — `/fixtures/:id`
- `mount`: load fixture; compute `@live_buzz?`. Flag off → redirect to leaderboard.
  Subscribe to `"fixture:#{id}"`.
- Renders: header (teams, live score, `live_minute`), **all players' locked picks — only
  once `Predictions.locked?(fixture, now)`** (hard anti-copy rule), the "if it ends now"
  projected leaderboard, and the scenario narratives.
- `handle_info({:live_update, _}, socket)`: reload live score + re-run `project`/`Buzz`,
  re-render.

### FunWithFlags
- Add `{:fun_with_flags, "~> 1.12"}` with the Ecto persistence adapter; run its migration
  (creates `fun_with_flags_toggles`). Flag: `:live_buzz`. Enable on prod via
  `rpc "FunWithFlags.enable(:live_buzz)"`.

## Data flow

```
LiveScoreSync (Oban, 30s, during window)
  └─ writes live_* to fixture ─ broadcast "fixture:{id}" {:live_update, id}
        └─ FixtureLive.handle_info → Standings.project/3 + Buzz → push to browser
```

## Flag gating (dark ship)

`@live_buzz?` computed in each LiveView mount, passed to components:
- **off:** `/fixtures/:id` redirects; no "Live now" card; My Predictions cards render
  exactly as today (a `:live`/`is_live` fixture falls through to the scheduled rendering).
- **on:** live score + `LIVE` badge on cards; "Live now" card on the leaderboard; drill-down active.

## UI surfaces (all gated)
1. Live score + minute + `LIVE` badge on My Predictions fixture cards.
2. "Live now" card on the leaderboard front door → links to `/fixtures/:id`.
3. `/fixtures/:id` drill-down (picks post-kickoff, projection, scenarios, YOU framing).

## Testing
- **Pure:** `project/3` (booster + risky + round-bonus honoured; nothing persisted);
  `Buzz` scenario diffs and narratives (overtakes, YOU framing).
- **Worker:** injected fetch → writes `live_*`, sets/clears `is_live`, broadcasts,
  respects the window (mirrors `FifaLiveCaptureTest`).
- **LiveView:** flag-off redirects; flag-on shows picks **only after kickoff**, correct
  projection + scenarios; a `{:live_update, …}` message re-renders. Picks hidden
  pre-kickoff is a dedicated test (hard rule).
- **Flag:** off vs on behaviour asserted at the mount boundary.

## Build order (each chunk shippable behind the off flag)
1. Migration (`live_*` cols) + FunWithFlags (dep, migration, `:live_buzz`).
2. `Standings.project/3` + `Buzz` — pure, fully tested (the brain; no UI).
3. `Workers.LiveScoreSync` + tests.
4. Live score on My Predictions cards (gated).
5. `/fixtures/:id` `FixtureLive` — picks + projection + scenarios + PubSub (the headline).
6. "Live now" card on the leaderboard.

Deploy after each chunk (flag off). Flip `:live_buzz` on when satisfied. Tonight's
Portugal v Congo DR (kickoff 2026-06-17 17:00Z) is the first live test of `LiveScoreSync`
against real data; the UI can be enabled mid-match or later.

## Out of scope (later)
- Knockout first-team/first-scorer in the projection (group stage needs only goals;
  knockout projection treats first-scorer points as 0 until known).
- Caching `Standings.leaderboard/0` (predictex-a4j) — relevant once projection load grows.
- Persisting/replaying live state history; OCR; iOS Shortcut.
