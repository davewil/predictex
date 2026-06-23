# predictex-iy1 — FIFA-capture result fallback (design)

**Date:** 2026-06-23
**Bead:** `predictex-iy1` (P2, feature)
**Status:** design approved, pre-implementation

## Problem

openfootball is the authoritative result source (the "two-writer rule": FIFA drives the
`live_*` columns, openfootball owns `status` + the final score). But openfootball **lags** —
it is community-maintained and can be hours behind, or miss a match entirely.

This bit us live on **France v Iraq (2026-06-22)**: the match finished 3-0, but openfootball
never published a result (its feed lists the fixture with no `score` field), so the fixture sat
`status: :scheduled` / `home_goals: nil` for hours and contributed **0** to everyone's
leaderboard. It was settled by a manual admin override.

We already capture the authoritative FIFA final via the live feed (`Predictex.Capture`). The
goal: **automate that as a fallback** — when openfootball has no result for a fixture but our
FIFA capture shows it finished, settle the fixture provisionally from the captured score.
openfootball stays primary; the fallback only fills the gap.

This realises `docs/plan.md`'s "near-live fallback" intent, but using our **own FIFA capture**
rather than an external `worldcupapi.com` dependency.

## Approach (chosen: A — silent, no migration)

Settle silently from the FIFA capture; **no provenance column, no migration.** The board shows
the result like any other; openfootball overwrites it the instant it publishes a real result.
The alternative (B: a `result_source` column to badge results "provisional (FIFA)") was rejected
for v1 on YAGNI grounds — FIFA's `MatchStatus 0` finished score is authoritative (same feed as
the live score), openfootball reconciles anyway, and B is a migration plus UI work. B can layer
on later if visibility is wanted.

## The design is two coordinated changes

### Change 1 — `Ingest` no-downgrade guard (correctness prerequisite)

**Why it is needed.** `Predictex.Results.Openfootball.ft_score/1` returns `{nil, nil, :scheduled}`
for any fixture without an integer `ft` score. So while openfootball lags, each 15-min
`ResultSync` tick parses the lagging fixture as `:scheduled / nil / nil` and
`Ingest.upsert_fixture` cast-writes that over a settled result — **reverting it every tick**,
with the fallback re-settling right after. That is a match-day flicker (`Ingest.commit`
broadcasts `fixtures_changed` mid-revert, so dashboards blink scheduled→completed every tick).

**The guard.** In `Ingest.upsert_fixture/2`, when the **existing** fixture is already
`:completed` and the **incoming** openfootball attrs have no result (`status != :completed`),
drop the result-derived fields from the update and keep the settled result:

```
@result_fields [:status, :home_goals, :away_goals,
                :first_scorer_side, :first_scorer_player, :first_goal_owngoal, :goals]
```

Non-result fields (`team1`, `team2`, `group`, `kickoff_at`, `source_num`, `external_ref`,
`round_id`) still update — so the predictex-g8m knockout bracket-resolution path (teams resolve
in place) is untouched.

**Invariant established:** *a `:completed` fixture never reverts to `:scheduled` via a sync.*
This is correct independent of the fallback — a finished match shouldn't be nulled because the
feed momentarily lacks its score, and postponements happen pre-play (a not-yet-`:completed`
fixture), so the guard is safe. openfootball still **overwrites** a `:completed` fixture when it
has a *real* result (incoming `status: :completed` → full write), so authoritative correction is
preserved.

### Change 2 — `Predictex.Results.FifaFallback` (the fallback itself)

A new module following the codebase's Gather → Decide → Act shape (pure core, effects at edges).

**Pure decision — `settle_attrs/2`** (no DB; testable on hand-built bodies):

```
settle_attrs(fixture, body) :: {:ok, attrs} | :skip
```

Returns `{:ok, %{status: :completed, home_goals: h, away_goals: a}}` only when **all** hold:
- `fixture.round.stage == :group` (group stage only — see Scope),
- `fixture.status != :completed` (only settle unsettled fixtures),
- `body["MatchStatus"] == 0` (FIFA reports the match **finished**),
- `get_in(body, ["HomeTeam", "Score"])` and `["AwayTeam", "Score"]` are both integers.

Otherwise `:skip`.

**Edges — `run/0`:**
- **Gather:** candidate fixtures — `fifa_match_id` present, `status != :completed`,
  `kickoff_at` older than a full-time margin (`@min_elapsed_min`, ~100 min — guards against
  settling an abandoned/early `MatchStatus 0` frame), `:round` preloaded. For each, its latest
  captured detail body via `Capture.latest_detail_body/1`. The body source is injectable
  (`:fifa_fallback_body_fun`) so tests need no real captures.
- **Decide:** `settle_attrs/2` per candidate.
- **Act:** `Tournament.update_fixture/2` for each `{:ok, attrs}`; then one
  `Tournament.broadcast_change()` if anything settled, so live dashboards re-pull. Returns a
  summary map (`%{settled: n, candidates: m}`).

### Integration — `ResultSync`

`ResultSync.perform/1` runs the fallback **unconditionally after** the openfootball sync, so it
still fires when openfootball is **down** (the worst-lag case):

```
of_result = sync_fun().()
fb = fifa_fallback_fun().()        # FifaFallback.run/0, injectable for tests
Logger.info("result sync ok: ... fifa_fallback: #{inspect(fb)}")
case of_result do
  {:error, reason} -> Logger.error(...); {:error, reason}   # Oban retries openfootball
  _summary -> :ok
end
```

`:fifa_fallback_fun` defaults to `&FifaFallback.run/0`; tests stub it (network-free), like the
existing `:result_sync_fun`.

## The two-writer rule — the bounded, deliberate exception

The fallback writes openfootball's columns (`status` / `home_goals` / `away_goals`) **only** for
an unsettled **group** fixture, **only** from a FIFA finished frame. It never touches a
`:completed` fixture, so admin overrides and openfootball results are safe. With Change 1 in
place, openfootball reclaims authority on its next sync that carries a *real* result (overwrites
the provisional); a no-result tick leaves the provisional intact. `is_live` is **not** touched —
`Workers.LiveScoreSync.clear_stuck_live/1` already clears it once `status == :completed`.

## Scope & guards

- **Group stage only (v1).** A `MatchStatus 0` finished frame's score is the regulation final for
  a group match. Knockouts add extra-time / penalties (regulation goals = `Period ∈ {3,5}`), which
  must reconcile with openfootball's FT-excludes-ET handling — deferred to `predictex-uyf`.
- **`MatchStatus 0` + both scores integer** before settling.
- **`@min_elapsed_min` (~100 min)** since kickoff — don't settle an abandoned or glitched early
  finished frame.

## Prerequisite

`predictex-ius` (the weather-break capture fix). The fallback reads the captured `MatchStatus 0`
finished frame; the old fixed capture window dropped that frame for a delayed match. The finished
frame is recorded the tick it arrives (before capture stops), so `Capture.latest_detail_body/1`
has it once the capture fix is deployed. (For the historical France v Iraq fixture, capture
stopped at 74' with no finished frame — which is why it needed the manual settle; the fallback
covers matches going forward.)

## Testing

- **Pure `settle_attrs/2`** (hand-built bodies, no DB): finished group frame with both scores →
  `{:ok, ...}`; not-finished (`MatchStatus` 3 / nil) → `:skip`; missing a score → `:skip`;
  knockout fixture → `:skip`; already-`:completed` fixture → `:skip`.
- **`run/0` integration** (injected bodies): settles an eligible candidate; leaves a
  not-yet-finished candidate and an already-settled fixture alone; broadcasts on settle.
- **Full-tick durability (the interaction test):** FIFA-settle a group fixture, then run an
  openfootball sync that has **no result** for it, and assert it is **still** `:completed` with
  the FIFA score — proving Change 1 stops the revert/flap.
- **`Ingest` no-downgrade guard, directly:** an existing `:completed` fixture + an incoming
  no-result openfootball entry preserves `status`/score; an incoming **real** result (`:completed`
  + integer goals) overwrites; non-result fields (e.g. `team1`) still update in both cases.

## Out of scope

- Knockout fallback (ET/pens) — `predictex-uyf`.
- A `result_source` provenance column / "provisional" UI badge — Approach B, a possible later
  enhancement.
- Persisting the FIFA `goals` embed in the fallback — the match recap (`predictex-p4o`) already
  derives goals from the FIFA capture when they reconcile with the final, so the breakdown works
  without it.
