# FIFA-bracket third-placed resolution — design

- **Bead:** `predictex-e5o`
- **Date:** 2026-06-26
- **Status:** design (awaiting user review → `writing-plans`)
- **Builds on:** `predictex-80k` (per-fixture native R32 gate, deployed `v0.11.18`), `predictex-hco`
  WS1 (`Workers.KnockoutIds` + `Fifa.LiveIds` — already fetch FIFA `rounds.json`), and the
  `predictex-iy1` `FifaFallback` two-writer/no-downgrade precedent.

## Problem

Native R32 entry (`80k`) makes a fixture `:editable` only when **both** `team1`/`team2` are real
names (`Knockout.resolved_team?/1`). Those names come **only from openfootball** (the two-writer
rule: openfootball owns team identity). For a third-placed slot the openfootball feed carries a
candidate-set placeholder — e.g. USA's R32 opponent is the literal string `"3B/E/F/I/J"` — and
openfootball only rewrites it to the concrete team (`"Bosnia & Herzegovina"`) once the official
third-placed seeding publishes, around full group-stage completion.

FIFA's Match Predictor resolves the same slot **earlier**. The R32 third-placed assignment is a
lookup keyed on *which 8 of 12* third-placed teams qualify; as groups lock, candidates are
eliminated and individual slots become **forced** before the whole table is known. FIFA reflects
that forcing immediately (it shows USA v BIH today); openfootball waits.

**Observed 2026-06-26:** FIFA showed 4 resolved R32 ties (RSA v CAN, BRA v JPN, NED v MAR,
USA v BIH); predictex showed the first 3 (all winner-v-runner-up) but rendered USA v
`3B/E/F/I/J` as `:pending` ("⏳ awaiting teams"). Verified against the live feed: openfootball still
literally holds `"3B/E/F/I/J"`. Not a predictex defect — faithful to a slower source. This feature
closes the gap so members can predict a slot the moment FIFA locks it.

## Goal

Resolve R32 placeholder slots (group-winner/runner-up **and** third-placed) into concrete team
names **as soon as FIFA's `rounds.json` carries them**, so `Knockout.resolved_team?/1` flips and the
native card becomes `:editable` — without waiting for openfootball — while never letting FIFA
corrupt or contradict openfootball's authoritative identity.

## Decisions (locked during discussion)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Source the early resolution from **FIFA `rounds.json`**, not a re-derived seeding table | We already fetch it (`Workers.KnockoutIds`); FIFA is the league's reference; avoids re-implementing the 495-combination elimination maths (the table spiked + rejected in `7qu`). |
| 2 | **No-downgrade / no-overwrite guard** (the keystone) | Same discipline as `iy1`: FIFA may FILL a placeholder slot but must NEVER overwrite a name openfootball already resolved, and must NEVER write a placeholder/blank over a real name. openfootball stays authoritative; FIFA is a bounded early-fill. |
| 3 | Only act on a fixture whose current `team1`/`team2` is a **placeholder** (`not Knockout.resolved_team?/1`) | The trigger and the guard are the same predicate `80k` already owns — one definition of "still a placeholder". |
| 4 | Reuse the existing cron/worker path (`Workers.KnockoutIds` or a sibling), self-arming + stop-before-fetch | No new schedule surface; piggybacks the `rounds.json` fetch that's already happening for `fifa_match_id`. |
| 5 | A FIFA-filled name is **provisional**; openfootball reclaims on its next real sync | Consistent with the two-writer rule. If FIFA and openfootball ever disagree once openfootball resolves, openfootball wins (it's authoritative); log the divergence. |

## The resolution rule

For each knockout fixture, for each side (`team1`, `team2`):

```
resolve_side(current_name, fifa_name) ::
  keep current        when Knockout.resolved_team?(current_name)   # openfootball/already-real wins — never overwrite
  fill fifa_name      when not resolved?(current_name)
                       and Knockout.resolved_team?(fifa_name)       # FIFA has a real name for a slot we hold as placeholder
  keep current        otherwise                                     # FIFA also still a placeholder → nothing to do
```

Properties (the guard, stated as invariants the implementation must satisfy):
- **Monotonic:** a side only ever goes placeholder → real, never real → placeholder, never real → different-real.
- **openfootball-authoritative:** once `Knockout.resolved_team?(current)` is true, this path never
  touches that side again (openfootball's later writes are unaffected; they go through `Ingest`).
- **Idempotent:** re-running on an already-filled fixture is a no-op.
- **Total:** a malformed/missing FIFA entry leaves the fixture untouched (never crashes, never blanks).

## Architecture / components

```
Workers.KnockoutIds (extend) OR Workers.KnockoutTeams (new sibling)
  └─ fetch rounds.json (already done) → for each KO fixture with a placeholder side,
     resolve_side/2 per the rule above → Tournament.update_fixture/2 (the admin write path,
     same as the preview task) → broadcast_change/0 on any change

Predictex.Fifa.<Bracket|LiveIds> (extend)   → parse resolved team names out of rounds.json
Predictex.Knockout.resolved_team?/1         → the trigger AND the guard predicate (unchanged, reused)
```

Open implementation question for the plan: **extend `Workers.KnockoutIds`** (it already walks the
KO fixtures + `rounds.json`, and team-resolution is adjacent to id-assignment) **vs. a new sibling
worker** `Workers.KnockoutTeams`. Leaning extend — the data fetch and the fixture set are identical,
and "assign id + fill resolved name from the same `rounds.json`" is one cohesive pass — but the
plan should confirm `Fifa.LiveIds.assign/1` exposes (or can expose) the resolved names alongside the
ids without muddying its current single responsibility.

## Write path

Resolution goes through `Tournament.update_fixture/2` (the existing admin/openfootball-shared write
that `mix predictex.preview_knockout` and `Ingest` use), so the changeset, the `source_num`
identity (`g8m`), and the `:fixtures_changed` broadcast all behave exactly as today. The guard
(decision 2) is applied **before** calling `update_fixture/2` — a no-op produces no write and no
broadcast.

## Interaction with the two-writer rule

This is a **third** writer of `team1`/`team2` (after openfootball-`Ingest` and the manual admin
path), so the no-downgrade guard is load-bearing, not cosmetic:
- FIFA fills `"3B/E/F/I/J"` → `"Bosnia & Herzegovina"` early. ✓
- openfootball later syncs the same fixture with the real name → unchanged (already real). ✓
- openfootball syncs a *no-result/placeholder* frame → the guard's monotonicity means FIFA's filled
  name is not reverted (mirrors `Ingest`'s existing no-downgrade guard from `iy1`). ✓
- FIFA ever reports a placeholder again (feed flor) → ignored (guard rejects placeholder-over-real). ✓
- FIFA and openfootball disagree on the *concrete* name → **openfootball wins** (decision 5); the
  reconciliation should `Logger.warning` the divergence so it's observable, but not flip-flop.

## Testing

- `resolve_side/2` (pure): placeholder→real fills; real stays (no overwrite); FIFA-placeholder is a
  no-op; malformed FIFA entry is a no-op; idempotent re-run. Property: monotonic (never real→placeholder).
- Worker/integration: a KO fixture with one placeholder side + a `rounds.json` stub that resolves it
  → fixture gains the real name, the other (already-real) side untouched, `:fixtures_changed`
  broadcast once; re-run → no second write/broadcast.
- Guard regression: an openfootball-resolved fixture + a (hypothetically divergent) FIFA name →
  fixture unchanged, divergence logged.
- End-to-end with `80k`: a `:pending` R32 card flips to `:editable` after the FIFA resolution writes
  its team names (the `Knockout.resolved_team?/1` trigger), without openfootball involvement.
- Flag-test isolation per the compile-env gotcha where flags are touched (none expected here).
- Gate: `mix precommit` green; all new code covered; no migration (additive worker logic only).

## Rollout

Additive — rides a normal deploy. Self-arming on the existing cron, stop-before-fetch, transient
(deletable from the cron once the bracket is fully real, like `KnockoutIds`). No flag needed: it
only ever *fills* placeholders, so with nothing to fill it's a no-op; with the `:native_ko_entry`
flag still gating member visibility, an early-filled slot simply becomes predictable sooner.

## Non-goals / YAGNI

- **Not** re-deriving the third-placed assignment ourselves (the 495-combination table — rejected in
  `7qu`); we read FIFA's already-computed answer.
- **No** change to scoring/standings, the booster, or the per-fixture gate states — this only changes
  *when* a slot's team names become real (the input to the existing `:pending`→`:editable` flip).
- **Not** touching group-stage fixtures (their identity is set at seed/ingest; never placeholders).
- **No** UI change — the `80k` per-fixture render already handles a fixture flipping to `:editable`.

## Consistency notes

- Resolution is as fresh as the FIFA `rounds.json` cron cadence (same as `hco` WS1) — minutes, not
  instant, but well ahead of openfootball for third-placed slots.
- A FIFA-filled slot is provisional until openfootball confirms; the rare disagreement resolves in
  openfootball's favour with a logged warning (decision 5). In practice FIFA's forced assignments are
  final, so disagreement should be vanishingly rare — the log is the safety net, not an expected path.
