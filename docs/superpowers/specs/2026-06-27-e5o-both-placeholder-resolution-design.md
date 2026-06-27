# e5o v2 — fill both-placeholder R32 fixtures FIFA has resolved — design

- **Bead:** `predictex-dum`
- **Date:** 2026-06-27
- **Status:** design (awaiting user review → `writing-plans`)
- **Builds on:** `predictex-e5o` (anchored-only FIFA team fills, v0.11.19), `predictex-ahi` (Ingest
  team-identity no-downgrade guard, v0.11.20), `predictex-7qu` (`GroupTables` pure standings).

## Problem

e5o v1 is **anchored-only**: it fills a placeholder side of an R32 fixture only when the *other*
side is already a resolved real team. The resolved side does double duty — it fixes orientation
(which FIFA name maps to `team1` vs `team2`) and validates the slot match (a spurious `slot_key`
hit fails because the anchor won't equal either FIFA name).

That leaves a gap, now visible in prod (v0.11.20, `/bracket` fixture 77):

```
ours:  Winner I (1I)  v  3rd · C/D/F/G/H        ← both sides placeholders
FIFA:  France         v  Sweden                 ← FIFA has resolved BOTH
```

Both our sides are bracket placeholders (`1I` and `3C/D/F/G/H`), so there's no resolved anchor →
e5o skips. The fixture stays `:pending` (and members can't predict it) until **openfootball**
resolves `1I`→France, after which v1's anchored path fills Sweden. We wait on openfootball's
slow KO-resolution for a match FIFA already knows in full.

**Goal:** fill **both** sides of a both-placeholder R32 fixture from FIFA the moment FIFA resolves
it — safely, without the blind positional `home→team1` guess v1 deliberately rejected.

## Why this is hard (what v1's anchor gave us, for free)

FIFA's `rounds.json` gives us two real names (France, Sweden) but **not** which is `team1` vs
`team2` in *our* bracket orientation. The codebase deliberately distrusts pair ordering —
`Crosswalk.match_key` is an unordered team-set and `Fifa.Cohort` carries explicit home/away
swap-handling *because FIFA and openfootball sometimes order a pair oppositely*. So we cannot
write `team1←homeSquadName, team2←awaySquadName` on faith. We need an independent signal that both
**orients** the pair and **validates** we matched the right `rounds.json` entry.

## The mechanism: a projection-validated anchor

A both-placeholder R32 fixture in 2026 is always **one winner/runner-up slot** (`1X`/`2X`) paired
with **one third-placed slot** (`3…`) — or, rarely, two winner/runner-up slots. The winner/runner-up
placeholder is resolvable from **our own group standings** (`GroupTables`, already built for
`/bracket`): `1I` → the team currently top of group I.

So: resolve the `1X`/`2X` side against `GroupTables`; if it yields a real team **T**, check `T`
matches one of FIFA's two names (after `Crosswalk.norm/1`). That single check does everything the
v1 fixture-anchor did:

- **Validates the slot match** — `T` matching a FIFA name proves this `rounds.json` entry is the
  right one (a spurious `slot_key` hit yields two unrelated FIFA names; `T` matches neither → skip).
- **Fixes orientation** — if `T` matches FIFA's *home*, then `team1←home, team2←away`; if `T`
  matches FIFA's *away*, swap. The third side takes whichever FIFA name `T` did **not** match.

Then fill **both** fixture sides with the **canonical** FIFA names (via the v1 `canonical_index`).
The winner side's fill is FIFA-sourced *and* projection-validated (we confirmed `T`≡that FIFA
name), not a raw projection write — so it's as trustworthy as v1's third-side fills.

> **Why `T` matching FIFA is strong enough.** FIFA only publishes a *resolved* slot once it's
> locked. So FIFA showing `France` for `1I` means group I is decided. Our provisional `GroupTables`
> leader agreeing (`T`==France) corroborates it. If our leader disagrees (group genuinely not
> settled, or a tiebreaker we compute differently) → `T` matches neither FIFA name → **skip** (no
> bad write). And the `ahi` no-downgrade guard + openfootball's real→real authority self-heal any
> residual error. Net: fill only when our standings and FIFA agree on the anchor; otherwise wait.

## Decisions (proposed — confirm in review)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Orient + validate via a **projection-resolved winner/runner-up side**, never blind positional | Preserves the v1 safety property (an independent anchor); the advisor explicitly rejected positional-trust in v1. |
| 2 | Fill **both** sides (all-or-nothing) or neither | A fixture is `:editable` only when both sides resolve; a half-fill leaves it `:pending` — no member-visible gain, just churn. |
| 3 | Skip unless a `1X`/`2X` side resolves to a real team AND it matches a FIFA name AND both FIFA names are canonical | Every condition is a guard against an unvalidated/garbage write. |
| 4 | Source orientation from the **pure `GroupTables` standings**, NOT the `Bracket` read-model | Honors e5o decision-5 (the write path must not depend on the `/bracket` *view*); pure standings are a shared core, not the read-model. See "Architecture". |
| 5 | **Orientation comes from the group-table projection** (the spike is done — see below) | `rounds.json` has no position hint, so the projection is the primary, only safe signal. |

> **Task-0 spike result (done, 2026-06-27):** a `rounds.json` r32 tournament entry exposes only
> `homeSquadName`/`awaySquadName`/`homeSquadId`/`homeSquadAbbr`/`date`/scores/venue — **no source
> bracket position or group per side.** (There's a FIFA `homeSquadId`, but we keep no FIFA-squad-id→
> group map, and building one is heavier than the projection.) So the group-table projection in
> "The mechanism" below is the **primary** orientation+validation path, not a fallback. No further
> spike needed.

## Architecture / components

```
Fifa.KnockoutTeams (extend)
  plan/4  (was plan/3)        + group_tables arg; both-placeholder branch in fill_for
  fill_for: t1_ph and t2_ph → project the 1X/2X side via group_tables → orient → fill both
  assign/1                   builds GroupTables from group-stage fixtures, passes them to plan

Predictex.Knockout (extend, optional but recommended)
  parse_slot/1               classify a placeholder: {:winner, g} | {:runner_up, g}
                             | {:third, [g]} | {:resolved, name} — the single grammar source
                             (Bracket.resolve_slot can refactor onto it later; out of scope here)

Predictex.Bracket.GroupTables (reuse, pure)   standings used to resolve 1X/2X → team
```

**The decision-5 tension (and resolution).** v1 kept `Fifa.KnockoutTeams` free of any `Bracket`
dependency. v2 needs group standings to orient. Resolve it by depending only on the **pure
`GroupTables` standings** (`GroupTables.build/1` → `%{group => [%{team: …}, …]}`) plus a tiny
position lookup (`tables |> Map.get(group) |> Enum.at(pos-1)`), **not** `Bracket.resolve_slot/2`
(the read-model). Owning the `1X`/`2X` parse in the neutral `Knockout` module (decision 5's home
for the placeholder grammar) keeps `KnockoutTeams` depending on (a) `Knockout` (grammar) and (b)
`GroupTables` (pure standings) — both shared cores, never the `/bracket` view.

## Write path

Unchanged from v1: fills go through `Tournament.update_fixture/2` (only `team1`/`team2`), broadcast
once on change, and are protected end-to-end by the `ahi` Ingest no-downgrade guard (so a v2 fill
survives the next openfootball ResultSync exactly as v1 third fills now do). Both-placeholder fills
are still **monotonic** placeholder→real.

## Edge cases

- **Group not yet decided / our leader ≠ FIFA's resolved team** → `T` matches neither FIFA name →
  skip; fixture stays `:pending` until standings and FIFA agree.
- **Provisional-tie at the anchor position** (`7qu`/`v4k`: rank-1 row tied/0-games) → treat as
  unresolved for anchoring (don't anchor on a coin-flip leader); skip. (Reuse the `v4k`
  provisional predicate if it lands.)
- **Two winner/runner-up sides** (no third, e.g. `Winner H v Runners-up J`) → either side can anchor;
  resolve both via standings, require BOTH to match the two FIFA names (a stronger cross-check),
  then fill. If both already resolve from standings the fixture is moot for FIFA — openfootball will
  fill it imminently — so this case is low-value; treat it the same (fill if FIFA confirms) but
  don't special-case it.
- **Third FIFA name not in `canonical_index`** (unknown team) → skip (don't write a non-canonical
  name); fixture stays `:pending`.
- **openfootball later resolves the winner/runner-up side itself** → real→real, the `ahi` guard
  allows it (openfootball stays authoritative on the concrete name).
- **A later-round both-placeholder** (`W89` v `W90`) → no group-table projection possible (not a
  group slot) → always skip. v2 is R32-scoped (group→KO boundary) by construction.

## Testing

- `Knockout.parse_slot/1` (pure): each placeholder form → its classification; total.
- `KnockoutTeams.plan/4` both-placeholder cases (pure, with hand-built group tables):
  - `1I` resolves to France (top of group I), FIFA `France v Sweden` → fills `team1=France,
    team2=Sweden` (orientation from the anchor).
  - same fixture, FIFA lists `Sweden v France` (swapped) → still fills `team1=France` (anchor
    re-orients) — the swap-safety property.
  - `1I` resolves to a team matching NEITHER FIFA name → `{}` (skip).
  - `1I` unresolved (group not decided / provisional tie) → `{}` (skip).
  - third FIFA name not canonical → `{}` (skip, all-or-nothing).
- End-to-end + `ahi`: `assign` fills a both-placeholder fixture, a later openfootball placeholder
  sync preserves it (the regression already covers the guard; add the both-placeholder shape).
- End-to-end + 80k: the `:pending` fixture flips `:editable` once both sides fill.
- Gate `mix precommit` green; no migration; no new deps.

## Non-goals / YAGNI

- **No blind positional `home→team1` fill** — orientation always comes from a validated anchor.
- **No projection-only write** — we never write a team into a fixture from our standings alone; the
  standings only *validate + orient*; the names written are always FIFA's (authoritative).
- **No new render/UI** — 80k's per-fixture gate already flips `:pending`→`:editable` when both sides
  resolve; v2 only changes *when* both names land.
- **No change to scoring/standings/booster** — entry-availability only.
- **Not** retro-resolving later-round (`W/L`) placeholders — R32 group→KO boundary only.

## Rollout

Additive; rides the existing `Workers.KnockoutTeams` cron (`*/10`, stop-before-fetch). No flag —
it only ever fills placeholder fixtures FIFA has resolved + our standings corroborate, so it's a
no-op until both agree. Member visibility stays gated by `:native_ko_entry`.

## Open questions for review

1. **Architecture (decision 4):** OK to have `Fifa.KnockoutTeams` depend on the pure
   `Bracket.GroupTables` standings + a `Knockout.parse_slot/1` grammar helper (but NOT
   `Bracket.resolve_slot/2`, the read-model)? This is the one place v2 widens v1's dependency
   surface; the proposal keeps it to shared pure cores. Alternative: lift the standings computation
   into a neutral module both `Bracket` and `KnockoutTeams` consume.
2. **Value vs. scope:** the high-value case is *winner-v-third* (e.g. fixture 77 France v Sweden);
   *winner-v-runner-up* both-placeholder fixtures resolve from openfootball almost as fast. Worth
   handling both uniformly (simpler), or scope v2 to winner-v-third only? (Proposed: uniform.)

(The `rounds.json` position-hint question is **resolved** — see the Task-0 spike result above; no
hint exists, so the group-table projection is the primary path.)
