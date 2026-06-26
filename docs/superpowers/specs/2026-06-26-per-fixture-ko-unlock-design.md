# Per-fixture native R32 unlock — design

- **Bead:** `predictex-80k`
- **Date:** 2026-06-26
- **Status:** design (awaiting user review → `writing-plans`)
- **Builds on:** `predictex-5q6` (the `:native_ko_entry` flag + gate, deployed v0.11.17) and
  `predictex-2ww` (native KO entry UX). Subsumes the write-safety half of `predictex-cij`.

## Summary

FIFA's Match Predictor unlocks each Round-of-32 match **the moment its two teams resolve**, so
members can predict the decided matches now (group stage still finishing) instead of waiting for the
whole bracket. predictex currently gates native KO entry at the **round** level — the entire R32
round opens only when its predecessor (the last group round) is fully `:completed` (`round_open?/1`,
~28 Jun). This change replaces that round-level gate with a **per-fixture** gate so the R32 tab
becomes a mix: editable where teams are known and kickoff is future, read-only where kicked off, and
"awaiting teams" where a slot is still a placeholder.

## Decisions (locked during brainstorming)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Gate native KO entry **per fixture**, not per round | Match FIFA; let members predict resolved R32 matches now. |
| 2 | Three fixture states: **`:editable` / `:locked` / `:pending`** | Captures the mixed reality of a partially-resolved round. |
| 3 | A resolved-but-kicked-off fixture is **read-only + the existing `/fixtures/:id` live-recap CTA** | Keep this focused on the *entry* gate; the in-round inline recap stays out of scope (`cij`). |
| 4 | Booster: **commit-at-kickoff** | Movable among editable fixtures; once the boosted fixture kicks off it's committed to that match for the round — a second booster is rejected with a clear message, never a constraint crash. Matches the existing "booster on a locked fixture is preserved" semantics and is cleanly expressible with the current `locked?/2`. |
| 5 | Shared placeholder/resolution predicate lives in a **neutral `Predictex.Knockout` module**, not `Bracket` | `Bracket` is a read-model built for `/bracket`; the core write path must not depend on it. Both consume `Knockout`. |
| 6 | The `:native_ko_entry` flag still gates everything (off → read-only FIFA-import grid) | Preserves the dark-ship/rollout mechanism from `5q6`. |

## The gate model

For a **knockout** fixture, a pure function classifies its entry state at `now`. It lives in
`Predictions` (it's prediction-*availability*, and it reuses `Predictions.locked?/2` so the
lockout definition stays single-sourced); it combines the resolution predicate from `Knockout`
with the existing lockout check:

```
Predictions.fixture_entry_state(fixture, now) ::
  :pending   — Knockout.resolved_team?(team1) and Knockout.resolved_team?(team2) is NOT both true
               (a slot is still a placeholder: "1G", "2J", "3A/B/C/D/F", "W89")
  :locked    — both teams resolved AND Predictions.locked?(fixture, now) (kickoff passed)
  :editable  — both teams resolved AND not locked (kickoff in the future)
```

Order matters: `:pending` is checked first (you cannot predict a match with an unknown team, even if
its scheduled kickoff has somehow passed). Group-stage fixtures and the flag-off path never reach
this function — they keep the read-only FIFA-import grid.

`Knockout.resolved_team?/1` is the keystone — a team slot is *resolved* iff its string is **not** a
placeholder. Placeholder forms (the inverse): `^[12][A-L]$` (group winner/runner-up), `^3[A-L](/[A-L])+$`
(third-placed candidate set), `^[WL]\d+$` (later-round winner/loser-of). Anything else is a resolved
real team name. (Edge, inherited from the `/bracket` regexes: a bare `3A` reads as resolved — harmless,
real 2026 R32 thirds are always multi-group sets.)

## Architecture / components

```
Predictex.Knockout (NEW, pure)
  └─ resolved_team?/1            placeholder ⇆ real-name predicate (owns the regexes)

Predictex.Bracket (refactor)    → consumes Knockout.resolved_team? (drops its own copy of the regexes)
Predictex.Predictions           → fixture_entry_state/2 (resolved_team? + locked?);
                                  save_round_predictions/5 gains a resolution partition + booster guard
PredictexWeb.MyPredictionsLive  → per-fixture render switch on Predictions.fixture_entry_state/2
```

### `Predictex.Knockout` — new pure module

Owns the placeholder regexes and `resolved_team?/1`. Pure, no Repo/Ecto. `Bracket` is refactored to
call `Knockout.resolved_team?/1` instead of carrying its own placeholder regexes, so "what counts as
a resolved team" has exactly one definition (data-contract consistency). The state classifier
`fixture_entry_state/2` lives in `Predictions` (above), not here, so `Knockout` has no dependency on
the lockout rule.

### Render — `MyPredictionsLive`

- The gate changes from `editable_round?/2` (flag AND knockout AND `round_open?`) to
  `native_ko_round?/2` = flag-on-for-player AND `stage == :knockout`. `round_open?` is no longer
  consulted.
- When `native_ko_round?` holds, the R32 tab renders **per fixture** via
  `Predictions.fixture_entry_state/2`:
  - `:editable` → the existing speedy goal-entry card (single-digit inputs, first-scorer/booster
    image toggles, the `RoundEntry` colocated hook + sr-only inputs) — unchanged.
  - `:locked` → read-only saved pick + the existing `/fixtures/:id` live/recap CTA (the same
    component group fixtures use post-kickoff).
  - `:pending` → a read-only "⏳ awaiting teams" card showing the slot labels (e.g. "Germany v
    3rd · A/B/C/D/F").
- The `phx-submit="save_round"` form wraps the whole tab; only `:editable` cards emit inputs, so a
  normal submit carries only editable rows.

### Write path — `Predictions.save_round_predictions/5`

Today it partitions rows by **round-membership** then **lockout**. Two additions, composed in:

1. **Resolution partition (defense in depth).** Among known, unlocked rows, any whose fixture is
   `:pending` (a placeholder team) is rejected → result `:pending`, never written. The render emits
   no inputs for pending fixtures, so this only fires on a crafted payload — same posture as the
   flag and the membership/lockout guards.
2. **Commit-at-kickoff booster guard.** Before the booster-clear/upsert, if a **locked** fixture in
   this round already holds `booster=true` and the incoming rows set a booster on a *different*
   fixture, return `{:error, :booster_locked}` (carrying the locked fixture, for the flash) rather
   than letting the "one booster per player per round" partial unique index roll the transaction
   back. The member keeps their committed booster and gets a clear message.

The result map gains `:pending` alongside the existing `:upserted` / `:locked` / `:unknown`. The
booster guard short-circuits to `{:error, :booster_locked}` (handled in the LiveView like the
existing `:booster_on_blank` flash).

## Error handling

- `:pending` rows → silently not written (the UI never offers them; a crafted one is dropped).
- `{:error, :booster_locked}` → a specific flash naming the committed fixture; nothing else in the
  submit is lost (the save is rejected atomically, the member re-submits without the new booster).
- `:locked` / `:unknown` → unchanged from today.

## Testing

- `Knockout` (pure): `resolved_team?/1` over every placeholder form + real names (totality, no raise).
- `Predictions.fixture_entry_state/2`: the three states incl. precedence (pending beats a passed
  kickoff); reuses `locked?/2` (no second lockout definition).
- `Bracket`: a regression test confirming the refactor to `Knockout.resolved_team?/1` left
  `resolve_slot/2` behaviour identical (the existing `bracket_test.exs` cases must still pass).
- `Predictions.save_round_predictions/5`: a `:pending` row is rejected and not written; the
  commit-at-kickoff booster guard returns `{:error, :booster_locked}` (no constraint crash) and
  preserves the committed booster; editable rows still `:upserted`; membership/lockout unchanged.
- `MyPredictionsLive`: the R32 tab renders all three states correctly (editable inputs, locked
  read-only + CTA, pending "awaiting teams"); flag-off → read-only grid; a forged `save_round` for a
  pending fixture is dropped; the booster-locked submit shows the flash.
- **Replace** the 28-Jun cutover test (`my_predictions_live_test.exs:442`, `@tag :native_ko`): its
  round-flip premise is deleted. New test — a single fixture flips read-only→editable when **its own**
  `team1/team2` are rewritten from placeholders to real names and `Tournament.broadcast_change()`
  fires (the real per-fixture unlock path).
- Flag-test isolation per the compile-env gotcha: enable in `setup`, `FunWithFlags.Store.Cache.flush/0`
  in `on_exit` — NOT a `config/test.exs` `:cache` override.
- Gate: `mix precommit` green; all new code covered.

## Cleanup in the blast radius

- **`round_open?/1`:** the entry gate stops calling it. After the preview-task change below, grep for
  remaining callers; if none, remove `Tournament.round_open?/1` + its direct test and update
  `docs/rules.md` §4 to the per-fixture availability rule. If a caller remains, keep it and note why.
- **`mix predictex.preview_knockout`:** its current job (settle the predecessor round so `round_open?`
  flips) no longer surfaces editable entry. Update it to **resolve a couple of R32 fixtures' teams**
  (rewrite `team1/team2` placeholders to real names) so editable fixtures appear in local dev. Keep it
  idempotent + loud, update its tests.
- **`predictex-cij`:** the per-fixture write-safety it asked for is delivered here; narrow it to just
  the inline-recap-within-round nicety (explicitly out of scope) or close it.

## Consistency notes

- Editability is only as fresh as the **openfootball / ResultSync ingest** that rewrites `team1/team2`
  from `1H`/`2J` to real names (eventual consistency, ~15-min cadence). A match is predictable in
  predictex shortly after FIFA/openfootball resolve it, not instantly.
- **Scoring and standings are untouched** — they key off fixture *completion* and the existing
  `Scoring`/`Standings` paths, not the entry-gate state. This change is entry-availability only.

## Rollout

Deploy with the per-fixture gate; then enable `:native_ko_entry` for all members
(`FunWithFlags.enable(:native_ko_entry)`) — the operational step that makes resolved R32 matches
predictable for everyone, not just admins. Kill switch = disable the flag (no redeploy).

## Non-goals / YAGNI

- No inline live/recap within the R32 tab (kicked-off → read-only + the existing `/fixtures` CTA).
- No change to group-stage entry (still frozen / FIFA-import).
- No change to scoring, standings, or the booster's per-round-single-booster rule (only *when* it
  commits).
- No first-scorer import work (separate: `predictex-i9k`).
