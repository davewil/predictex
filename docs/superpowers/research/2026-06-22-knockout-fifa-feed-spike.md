# Phase 0 Spike — FIFA knockout feed: squad-roster availability & goal-period structure

**Date:** 2026-06-22
**Plan:** `docs/superpowers/plans/2026-06-22-knockout-game-phase1-foundation.md` (Task 0)
**Design spec:** `docs/superpowers/specs/2026-06-22-knockout-game-native-predictions-design.md`
**Purpose:** De-risk the *follow-up* plan (player picker + FIFA result authority). Pure
investigation — no production code. Gates spec decision 8 (does the v1 picker ship, or is it a fast-follow?).

## Method

- **Step 1 / 3 (id-join, goal structure):** banked baseline bodies in `tmp/fifa-capture/baseline/`
  (4 finished group matches: `400021447/464/496/498`), decoded through the app's `Jason`.
- **Step 2 (pre-match roster):** live fetch of the same `/detail` endpoint the capture worker uses
  (`LiveScoreSync`: `https://api.fifa.com/api/v3/live/football/17/285023/289273/{IdMatch}`) for four
  **upcoming** group fixtures (kickoff 7.5h–28h out), discovered via the FIFA calendar
  (`/api/v3/calendar/matches?idseason=285023&idcompetition=17`). Egress to `api.fifa.com` works from
  the dev box (no auth key). Dev DB has no `fifa_match_id` (prod-only), so match ids came from FIFA directly.

## (a) Squad / scorer `IdPlayer` id-join — CONFIRMED ✅

The structure already used in production (`capture.ex` `player_map/1`, `goal_events/1`) holds in the banked data:

- Each team body carries **`HomeTeam.Players[]` / `AwayTeam.Players[]`** (26 entries per team = full squad,
  not just the XI). Each player: `IdPlayer`, `PlayerName`, `ShortName`, `IdTeam`, `ShirtNumber`,
  `Position`, plus lineup fields (`FieldStatus`, `LineupX/Y`, `Captain`, `Status`).
- Goals are nested **per team** (`HomeTeam.Goals[]` / `AwayTeam.Goals[]`), **not** top-level. Each goal:
  `IdPlayer`, `IdTeam`, `Period`, `Minute`, `Type`, `IdGoal`, `IdAssistPlayer`.
- **Join verified end-to-end:** on `400021464` all **8/8** goal `IdPlayer`s resolve against the combined
  roster map (e.g. `492363→NMECHA`, `411367→HAVERTZ` twice). Zero misses.

→ **First-scorer id-based scoring is viable** once a roster is in hand. The exact-match `IdPlayer`
contract the design assumes is real.

## (b) Pre-match roster availability — ABSENT days ahead ⛔ (the picker gate)

The `/detail` endpoint, queried for upcoming fixtures, returns **teams resolved but rosters empty**:

| Match | Kickoff (UTC) | MatchStatus | Period | Teams | Roster home/away |
|-------|---------------|-------------|--------|-------|------------------|
| 400021491 | 2026-06-23 00:00 | 1 (scheduled) | 0 | Norway v Senegal | **0 / 0** |
| 400021499 | 2026-06-23 03:00 | 1 | 0 | Jordan v Algeria | **0 / 0** |
| 400021503 | 2026-06-23 17:00 | 1 | 0 | Portugal v Uzbekistan | **0 / 0** |
| 400021506 | 2026-06-23 20:00 | 1 | 0 | England v Ghana | **0 / 0** |

Contrast: the **finished** baseline bodies carry the full 26-man `Players[]` per team. So rosters populate
only at/around match time (lineup release, conventionally ~1h pre-kickoff), **not** days ahead when a
knockout round opens for predictions.

→ **VERDICT (spec decision 8):** the squad roster is **not** available pre-match from `/detail`. The v1
**player picker cannot** be sourced from this endpoint at round-open time. This **confirms the Phase 1
decision to ship the KO game *without* the player picker** ("minus the player picker"). The picker is a
**fast-follow**, contingent on a different source (see recommendation).

## (c) Goal `Period` / `Minute` structure — regulation filter

Across the 4 banked matches (17 goals), regulation goals map cleanly:

- **`Period 3` = first half** (minutes `6'`…`45'+5'`)
- **`Period 5` = second half** (minutes `47'`…`90'+12'`)
- **Match-level `Period 10` = finished after regulation** (all 4 baselines; `MatchTime` e.g. `"98'"`).
- `Minute` is a **string** carrying stoppage (`"90'+4'"`) — already handled by `Openfootball`/`LiveScore`.
- `Type` (matches the embedded `goals.type` enum `[:penalty, :own_goal, :regular]`): **1** seen on a
  `45'+5'` goal (penalty), **2** = regular (the bulk), **3** = own goal (credited to the beneficiary side
  by the ingest layer; the `uyf`/Type-3 work).

→ **Regulation first-scorer filter:** keep goals with `Period ∈ {3, 5}` (excludes extra time). **OPEN
UNKNOWN:** ET period values are not observable until the first ET knockout match (**R32 ≈ 28 Jun**) —
expected `7` (ET first half) / `9` (ET second half) by the odd-number pattern, and a match-level `Period`
other than `10`, but this is **unconfirmed**. The design's safety net (FIFA-regulation scoreline reconciled
against openfootball `ft`, which is verified regulation-only) doubles as the ET-filter regression check that
can only run from 28 Jun.

## (d) Recommendation for the follow-up plan

1. **Player picker — defer, and do NOT source the squad from `/detail` pre-match.** Options, in
   preference order:
   - **(i) Spike a dedicated FIFA squad endpoint** (team-squad / competition-squads) that lists the
     tournament squad days ahead, keyed on the same `IdPlayer`. This is the clean path to the
     searchable-dropdown → `IdPlayer` → exact-match scoring the design wants. Needs its own short spike
     before the follow-up commits to it.
   - **(ii) Free-text first-player in v1**, with `IdPlayer` matching deferred until a squad source exists
     (string-normalised compare meanwhile, as `Scoring` already does for `first_scorer_player`). Lowest risk,
     ships immediately, but no exact-id scoring.
   - **(iii) Lineup-time picker** (roster appears ~1h pre-kickoff) — **rejected**: far too late for a
     pre-round picker; the KO round opens days before kickoff.
   - **Net:** make the follow-up plan's picker a **squad-endpoint spike → picker** sub-thread, with free-text
     as the fallback if the squad endpoint doesn't pan out. Phase 1 already ships the game without it, so there
     is no schedule pressure.

2. **Regulation filter — implement as `Period ∈ {3,5}`** for the FIFA-authoritative first-scorer, and wire
   the openfootball-`ft` reconciliation (already specified) so the first real ET match (28 Jun) both confirms
   the ET period values and regression-checks the filter. Log the ET-period values the moment they're observed.

## Cross-links

- Confirms: Phase 1 plan's "ships a working KO game **minus the player picker**".
- Feeds: the deferred follow-up plan (player picker + squad ingestion; FIFA result-authority / regulation filter).
- Related memory: `fifa-v3-live-api-contract` (endpoints, score path, `MatchStatus`/own-goal/scorer join).
