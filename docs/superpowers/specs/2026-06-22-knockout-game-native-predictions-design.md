# Knockout Game — native predictions, re-based at R32 — Design

**Date:** 2026-06-22
**Status:** draft (pre-implementation; brainstormed + advisor-reviewed 2026-06-22)
**Beads:** `predictex-2ww` (native in-app pivot — this supersedes/realises it for the knockouts),
`predictex-uyf` (knockout-ET goal filtering — wired in here), `predictex-hco` (FIFA bracket /
`fifa_match_id` backfill — bracket authority builds on it), `predictex-i9k` (xox knockout import —
superseded for KO by native entry).
**Relates to:** `Predictex.Scoring`, `Predictex.Standings`, `Predictex.Capture`, `Predictex.Fifa.*`,
`PredictexWeb.MyPredictionsLive`, the `fifa-v3-live-api-contract` + `openfootball-knockout-ft-timing`
memories.

## Summary

From the **Round of 32**, members make their predictions **natively in this app** (no FIFA
round-trip), the leaderboard is **re-based** (a fresh from-zero knockout board alongside the
existing cumulative one), and **FIFA is the data authority** for the knockout game. The group
stage is frozen as-is.

This is the `2ww` pivot, scoped to the knockout stage and extended with re-based scoring and a
FIFA-first data model.

## Decisions (locked — brainstormed 2026-06-22)

1. **Scope = knockout rounds only (R32 onward).** The group stage is **frozen**: already-imported
   picks and the current read-only display are untouched. Native entry never edits group rounds.
2. **Two leaderboards.** Keep the existing **cumulative/overall** board (all tournament). Add a
   **knockout-only** board that starts everyone at **0** at R32 and ranks only knockout points.
   Shown side by side.
3. **FIFA is the data authority** for the knockout game: bracket pairings, scoreline result,
   first-scorer (team + player), squads, and cohort/risky all sourced from FIFA. (See §"Data
   authority" for the one safety net on the scoreline.)
4. **First-player picked from a searchable squad dropdown**, stored as a FIFA **`IdPlayer`**, scored
   by exact id match against FIFA's scorer feed. (Contract verified — see below.)
5. **Entry on `/predictions`**: extend it from read-only to **editable for the currently-open
   knockout round**. Locked/past rounds stay read-only as now.
6. **FT-only (regulation) scoring is preserved** (`rules.md` §9.4). ET/penalties excluded — for the
   scoreline **and** for first team/player (a goal first scored in ET does not count as the first
   scorer; voids to "no first scorer"). This makes the open `uyf` ruling explicit.
7. **Native entry replaces the FIFA round-trip for knockouts.** The `/import` bookmarklet/paste flow
   is bypassed for KO; its beads (`xox`/`i9k`/`066`/`dnp`/`xww`/`fs6`) are marked **superseded** only
   once this lands (not closed now).
8. **v1 is the full knockout pick** — scoreline + first-team + searchable player picker + one
   booster/round + the knockout-only board — contingent on the spike confirming pre-match squad
   availability (§Phase 0); if not available, the picker degrades to a fast-follow (free-text or
   deferred), since scoring already gates the first-player component separately.

## Verified data contract (FIFA `/detail`)

Confirmed from `lib/predictex/capture.ex` + the `fifa-v3-live-api-contract` memory (no assumptions):

- The detail body embeds, per team, a `Players` roster and a `Goals` list **in the same response**
  — there is **no separate squad/players feed**.
- Each `Players` entry has an **`IdPlayer`** and localized `PlayerName`/`ShortName`.
- Each goal has the same-space **`IdPlayer`**, plus `Minute`, `Type` (1=pen, 2=open, 3=own goal),
  `Period`, `IdTeam`. Scoring **side** = the team whose `Goals` array holds it (`g.IdTeam`), never
  the scorer's roster team (own-goal handling).
- **Therefore:** the picker stores `IdPlayer`; the scorer feed's `goal["IdPlayer"]` matches it
  exactly. Squads come "for free" from the body we already capture (`Capture.goal_events/1`,
  `player_map/1`).

**Open (spike) unknown:** is the `Players` roster populated **pre-match** (for entry, days ahead),
or only near kickoff? The detail endpoint "works pre/live/post", but pre-match roster presence is
unconfirmed. This gates the v1 picker — see Phase 0.

## Data authority — scoreline safety net

The scoreline is scored against **FIFA goals, regulation-filtered** (the user's authority choice).
The regulation filter (`Period`/`Minute`) cannot be fully validated until a real ET knockout
(28 Jun+), so it ships with a **reconciliation oracle**, at no extra cost:

- openfootball commits the whole-match result **after the final whistle**, and its `score.ft` is
  **verified regulation-only** (`openfootball-knockout-ft-timing` memory: all five of 2022's ET/pens
  knockouts).
- At settle-time, reconcile **FIFA-regulation vs openfootball-`ft`**:
  - **agree** → confidence; score on FIFA as designed.
  - **diverge** (the signal that the ET filter misfired) → **log/flag and fall back to openfootball
    `ft`** for scoring.
- This catches the "botched ET filter misscores the first ET knockout, live" failure automatically,
  and doubles as the regression check the spike can't run pre-28-Jun.

First-team/first-player use FIFA goals filtered to regulation (`Period`/`Minute`); the
regulation-only first-scorer ruling (decision 6) is asserted in the scoring tests.

## Build units

1. **Squad ingestion.** A squad/players store keyed by `{team, fifa_player_id, display_name}`,
   populated from FIFA for **all surviving teams** (not gated on bracket pairings resolving — a team's
   squad is known once it's in the tournament). A `SquadSync` Oban worker (mirrors `CohortSync`:
   server-fetched, no member action, injectable source for tests). Source = the detail `Players`
   roster (per the spike) or a dedicated squad endpoint if the spike finds one.
2. **Native knockout entry.** Extend `MyPredictionsLive` (`/predictions`) to editable for the open
   knockout round: scoreline + first-team radio + **searchable player picker** (from the squad store)
   + one booster/round. Kickoff lockout reused (`Predictions.locked?/2`). A **lockout-aware
   member write path** (the existing `admin_*` writers skip lockout; reuse the
   `admin_save_round_predictions/3` sparse-grid + booster-on-blank validation, wrapped with the
   member lockout check). Validate at the boundary (LiveView discipline). `/import` links removed for
   KO.
3. **FIFA result authority (knockout).** Bracket teams auto-populate from FIFA (builds on `hco` WS1 /
   `Fifa.LiveIds`). First-scorer team + `IdPlayer` and the regulation-filtered scoreline derived from
   FIFA detail goals, reconciled per §"Data authority". Two-writer rule adjusted for KO.
4. **Re-based knockout-only leaderboard.** `Standings.knockout_leaderboard/0` — reuse the pure
   `rank/2` over knockout-stage fixtures only, from 0. Rendered alongside the cumulative board on `/`
   and/or `/predictions`.

## Schema / engine touch points

- `Prediction`: add **`first_scorer_player_id`** (FIFA `IdPlayer`). Keep `first_scorer_player`
  (string) for display and legacy group/admin data.
- `Scoring`: first-player matches by **`player_id` when present**, name fallback otherwise — so
  legacy data and the new id-based picks both score. Regulation-only first-scorer asserted.
- New squad/players table + migration; new `SquadSync` worker (cron, injectable source).
- `Standings`: add the knockout-scoped board (`knockout_leaderboard/0`), no change to `rank/2`.
- Web: `MyPredictionsLive` gains an edit mode for the open KO round + the second board; a player
  picker component (searchable, scoped to the fixture's two squads).

## Phasing (R32 ≈ 28 Jun — tight; ~6 days)

- **Phase 0 — Spike (runnable now, timeboxed):**
  - (a) **Pre-match `Players` roster availability** in the detail endpoint — fetch an upcoming
    fixture's detail. **Gates the v1 picker.** If absent pre-match → picker becomes a fast-follow,
    v1 ships scoreline + first-team + booster + board.
  - (b) **Goal `Period`/`Minute` structure** for the regulation filter — from the banked baseline
    samples (`tmp/fifa-capture/baseline/`: Argentina, Austria, Germany-pen `400021464`, Qatar-OG
    `400021447`) + one live fetch. (Full ET confirmation deferred to 28 Jun, covered by the
    reconciliation oracle.)
- **Phase 1 — Member core (before R32 opens):** squad ingestion + editable `/predictions` for KO
  (scoreline + first-team + picker + booster) + knockout-only board.
- **Phase 2 — FIFA result authority (before first R32 results settle):** bracket auto-populate +
  first-scorer-by-`IdPlayer` + regulation-filtered scoreline + openfootball reconciliation.

## Testing

- **Scoring (pure):** first-player matched by `player_id`; regulation-only first-scorer (ET goal
  does not become first scorer); FT-only scoreline unchanged; legacy name-fallback still scores.
  Build fixtures from **real captured** `IdPlayer`s from the banked samples (per CLAUDE.md
  fixture-honesty), not invented ids.
- **Squad ingestion:** worker populates the store from a stubbed FIFA body (injectable source);
  roster keyed by `IdPlayer`.
- **Entry (LiveView):** editable only for the open KO round; locked/past read-only; lockout enforced
  at kickoff; booster-on-blank rejected; picker scoped to the fixture's two squads; anti-corruption
  validation at the boundary.
- **Knockout-only board:** `knockout_leaderboard/0` excludes group fixtures; everyone starts 0 at
  R32; ranks only knockout points.
- **Reconciliation:** FIFA-regulation vs openfootball-`ft` — agree → FIFA; diverge → flagged +
  openfootball fallback.

## Out of scope / deferred

- Group-stage native entry (group is frozen; native entry is KO-only).
- Mirroring native picks back to FIFA (Predictex is the sole source for KO picks).
- Migration of group picks (they stay as-is on the cumulative board).
- Full ET-filter confirmation (deferred to the first real ET knockout; guarded by reconciliation).
- Deleting the `/import` surface (marked superseded, removed later under `2ww`).

## Open questions for the plan

- Squad source if the detail `Players` roster is **not** pre-match: is there a FIFA squad/team
  endpoint, or do we accept a kickoff-time roster (too late for entry) → free-text fallback?
- Exact `Period` value for extra time (unknown until an ET match) — the regulation filter must be
  written defensively (filter *to* known regulation periods/minutes, not *out* of an assumed ET
  value) and validated by the reconciliation oracle.
