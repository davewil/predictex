# "If your pick lands" — projected leaderboard (kcx) — Design

**Date:** 2026-06-21
**Status:** draft (pre-implementation; design agreed with user 2026-06-21)
**Bead:** predictex-kcx (P3)
**Relates to:** predictex-c46 (live-buzz what-if), `Predictex.Standings.project/3`,
`Predictex.Buzz`, `PredictexWeb.FixtureLive`, predictex-i1s (replay — must not collide).

## What this is

On `/fixtures/:id`, add an **"If your pick lands"** card that projects the leaderboard
**assuming the viewing member's own scoreline prediction for this fixture is the final
result** — answering "where do I end up if I'm right here?".

Distinct from the existing live-buzz "What if…" board (`c46`), which projects from the
**current live score**. This one is hypothetical on the **member's own pick**, and is
viewable **pre-kickoff and during play**, before the fixture settles.

## Why it's cheap to build

All the machinery already exists and is tested:

- `Standings.project(fixture_id, home, away)` swaps that one fixture to `:completed` in
  memory and reuses the pure `rank/2` — booster, risky/cohort, and round bonus all honoured,
  persists nothing. We feed it the viewer's pick `(h, a)`.
- `Buzz.scenarios_with_deltas/3` already enriches each projected row with `rank`,
  `prev_rank`, and `delta` (vs the current `Standings.leaderboard/0`, called once). We reuse
  that exact enrichment for a single assumed scenario.

So this is **no new scoring math** — one focused getter, one small `Buzz` helper, one assign,
one render section.

## Decisions (locked, agreed 2026-06-21)

- **Visibility:** render whenever the viewer **has a pick** for this fixture **and**
  `fixture.status != :completed` (pre-kickoff **and** during play). Never on a settled
  fixture — so it can never collide with `i1s` replay, which only runs on completed fixtures.
- **Anti-copy (input):** fetch the viewer's **own** pick directly via a focused getter — never
  the full picks list (that stays hidden pre-kickoff behind the existing reveal gate).
- **Anti-copy (output) — the load-bearing refinement.** The *projected board* itself is a
  pick leak pre-kickoff: `project/3` re-scores **every** player's own pick for this fixture
  against the viewer's scoreline, so each other player's `projected − current` rank delta
  reveals, per player, whether they got the result direction right (and, on a big jump, whether
  they likely picked the viewer's exact scoreline). That is precisely the information the
  pre-kickoff "Everyone's picks" reveal gate hides. Resolution (user-chosen 2026-06-21):
  - **Pre-kickoff (`not @picks_visible?`):** render **only the viewer's own projected row** —
    headline + own rank + own delta. The viewer's rank is an aggregate over all players, so it
    decomposes to nobody's individual pick — safe.
  - **Locked/live (`@picks_visible?`):** render the **full top-8 board** (picks are already
    public by then — no leak). This is Approach A's full card.
  - The card is therefore present across the whole agreed window; only the per-player rows are
    deferred to the reveal.
- **Reuse, no new math:** a single-scenario helper on `Buzz` returning `%{rows, viewer}`,
  reusing the `scenarios_with_deltas` row-enrichment. `Standings.leaderboard/0` is pulled
  **once** and shared (do not add a second full leaderboard pull — keeps `a4j` from worsening).
- **Rendering = Approach A:** reuse the "What if…" scenario-card look — one card titled
  "If your pick lands" with a headline (e.g. `🇧🇷 Brazil 2–1 → you'd move 7th ▲3`) + (post-
  kickoff) the top-8 board with the viewer row highlighted, identical styling to `@scenarios`.
- **UNCONDITIONAL** — no feature flag. Low-risk, read-only, reuses tested `project/3`;
  consistent with live buzz now being unconditional.
- **v1 = SCORELINE only.** `project/3` takes only `(h, a)`. A **knockout** projection would
  uniformly undercount the first-scorer bonus (it can't represent the assumed first-scorer) —
  DEFERRED refinement (would need `project` to optionally take the assumed first-scorer). Group
  stage (all we have until 28 Jun) is exact. The card carries a one-line caveat when
  `@knockout?`.
- **nil `prev_rank`:** a viewer with no completed fixtures yet is absent from
  `Standings.leaderboard/0`, so `delta` is nil. Show the projected rank **without an arrow** —
  do not suppress the card. (Mirror the documented `Buzz.narratives` nil case.)

## Data flow

```
mount / load_all
  └─ if viewer_pick && fixture.status != :completed:
       Buzz.pick_projection(fixture_id, pick.home_goals, pick.away_goals, viewer_id)
         ├─ current = Standings.leaderboard()            # pulled once
         ├─ projected = Standings.project(fixture_id, h, a)
         └─ enrich each projected row w/ rank/prev_rank/delta (as scenarios_with_deltas)
       → assign @pick_projection = %{rows: [...], viewer: %{rank, prev_rank, delta} | nil,
                                     home: h, away: a}
     else assign @pick_projection = nil

render
  └─ <section :if={@pick_projection}>
       headline (always): "<team1 flag> <team1> h–a → you'd {be|move} #rank {▲/▼delta}"
       :if @picks_visible? → full top-8 board (Approach A)   # picks public, no leak
       :if @knockout?      → caveat: "Scoreline only — excludes first-scorer bonus."
```

### New code surface

1. **`Predictions.get_player_fixture_prediction(player_id, fixture_id)` → `%Prediction{} | nil`**
   (focused getter; mirrors `list_fixture_predictions/1`'s query shape but scoped to one
   player). This is the anti-copy input boundary — only the viewer's own row.

2. **`Buzz.pick_projection(fixture_id, home, away, viewer_id)` → `%{rows, viewer}`**
   - Pure over `Standings`; persists nothing.
   - `rows` — the full enriched projected board (`[%{player_id, name, total, rank, prev_rank,
     delta}]`), same shape as a `scenarios_with_deltas` scenario's `rows`.
   - `viewer` — the row for `viewer_id` (or `nil` if the viewer isn't in the projected board).
   - Internally shares the single `Standings.leaderboard/0` index with the projected board.
     (Refactor opportunity: extract the row-enrichment from `scenarios_with_deltas/3` into a
     shared private fn so both call sites use one implementation.)

3. **`FixtureLive.load_all`** — compute `@pick_projection` under the visibility condition;
   assign `nil` otherwise. Recompute on the same `recompute?` path as `@scenarios`.

4. **`FixtureLive` render** — new `<section :if={@pick_projection}>` between "What if…" and
   "Everyone's picks", with the pre-kickoff/post-kickoff split above.

### Recompute cadence (known limitation, by design)

The pick projection depends on the viewer's pick (fixed) and the **current standings** — which
change only when *other* fixtures settle, events `FixtureLive` does not subscribe to (it
subscribes to `fixture:#{id}` only). So `@pick_projection` is effectively static per
`load_all`; it refreshes on this fixture's own updates. This is the same staleness the existing
live buzz already accepts — not a regression. (A future `a4j`/PubSub-broadening change would fix
both at once.)

### Replay interaction

`apply_frame/2` (replay) runs only on `:completed` fixtures, where the card is hidden by the
visibility rule. `apply_frame` must **not** recompute `@pick_projection` — it stays `nil`
throughout replay (it was set `nil` by the `load_all` that preceded replay start). Confirm no
accidental recompute in the replay path.

## Acceptance

- `/fixtures/:id` shows an "If your pick lands" card whenever the viewer has a pick and the
  fixture is not completed.
- Projection uses the real scoring engine (`Standings.project/3` → `rank/2`); no duplicated
  points math.
- Card shows the viewer's projected rank and rank change vs current standings (arrow omitted
  when the viewer has no current rank).
- **Pre-kickoff:** only the viewer's own row/headline is shown — no per-player board.
- **Post-kickoff/live:** full top-8 board with the viewer row highlighted.
- Hidden when the viewer has no pick; hidden when the fixture is completed.
- Knockout fixtures show the scoreline-only caveat.

## Tests

**Pure helper (`Buzz.pick_projection/4`):**
- Given a pick `(h, a)`, returns the projected board scored as if the fixture finished `h–a`
  (assert a known player's total/rank against `Standings.project` directly).
- `viewer` row carries the correct `rank`, `prev_rank`, `delta` vs current standings.
- Viewer with no completed fixtures → `viewer.delta == nil` (rank present).
- Pulls `Standings.leaderboard/0` once (shared index) — assert via the shape, not query count.

**LiveView (`FixtureLive`):**
- Pre-kickoff, viewer has a pick → card renders, shows the viewer's own row + delta; **does
  not** render any other player's row (anti-copy: assert other players' display names / their
  scorelines are absent from the card region).
- Post-kickoff (locked), viewer has a pick → full top-8 board renders, viewer row highlighted.
- Viewer has **no** pick → card absent.
- Fixture `:completed` → card absent (even with a pick).
- Knockout fixture → caveat line present.
- Anti-copy regression: the pre-kickoff DOM exposes only the viewer's own pick, never others'.

## Out of scope (v1)

- Knockout first-scorer-bonus accuracy (deferred; needs `project/3` to take an assumed
  first-scorer). Tracked as a follow-up on kcx or a new bead.
- Projecting for an arbitrary *other* player's pick (the bead's "consider also showing it for
  the row you're looking at" note) — not in v1; the anti-copy gate would forbid it pre-kickoff
  anyway.
- Cross-fixture live refresh of the projection (see cadence note; tied to `a4j`).
