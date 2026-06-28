# First-player-to-score picker (native KO entry) — design

- **Bead:** `predictex-u4k`
- **Date:** 2026-06-28
- **Status:** design (awaiting user review → `writing-plans`)
- **Builds on:** the native KO entry game (`predictex-80k`/`5q6`/`2ww`), the FIFA feed family already
  consumed (`rounds.json`, `squads.json`, `matchStats.json`), and the `Crosswalk` name-alias table.
- **Related:** `predictex-i9k` (KO first-scorer import + matching — the *scoring-data* half).

## Problem

The native KO entry form lets a member pick the **first team** to score (a home/away side toggle),
but **not the first player**. Yet `Scoring.first_player_points/3` (`scoring.ex:151`) awards **+10,
knockout-only**, free-text `norm`-matched (`trim + downcase`) against the actual first scorer; the
schema (`first_scorer_player`), the **admin** form, the save path (`parse_pick_rows` reads
`attrs["first_scorer_player"]`), and the display all already support it. So members forfeit the +10
on every KO fixture — and each fixture that kicks off locks it out permanently.

The player-picker was deferred because "no pre-match squad source." **That is now false.**

## Source — found + verified (2026-06-28)

`https://play.fifa.com/json/match_predictor/players.json` — a **static** feed in the same family we
already fetch (no auth, available pre-match). 408 KB, **1264 players, all 48 squads, full 26-man
rosters.** Per player:

```json
{"id": 430609, "firstName":"Matheus","lastName":"Cunha","knownName":null,"shortName":"Matheus Cunha",
 "squadId": 7, "position": 4, "status":"available", "stats":{"goals": 3}, "fifaId": 430609}
```

- `shortName` — display name.
- `position` — **1 GK · 2 DEF · 3 MID · 4 FWD** (FIFA's exact filter codes).
- `stats.goals` — the goals column the picker shows.
- `squadId` — joins to `squads.json` (`{id, name, abbr}`, e.g. `7 → "Brazil"`) and to the
  `homeSquadId`/`awaySquadId` already carried in `rounds.json` per match.
- `fifaId` — the **canonical** player id that matches the scorer `IdPlayer` in the match `/detail`
  goal events (the `2026-06-22` spike's 8/8 join), enabling exact-id scoring as a follow-up.

Verified against the live FIFA picker: Brazil (`squadId 7`) = 26 players; Matheus Cunha `position 4`
`goals 3` — exact match.

## The join

`squads.json` names equal our openfootball fixture team names (`Brazil`, `South Africa`, `Canada`,
`Japan`…); the few FIFA↔openfootball divergences (`Bosnia and Herzegovina`, `Côte d'Ivoire`…) are
already handled by `Crosswalk.norm/1`. So:

```
players.json (squadId, shortName, position, goals)
   ⋈ squads.json (squadId → name)
   ⋈ Crosswalk.norm(name)  ⋈  norm(fixture.team1 / fixture.team2)
→  the two squads for any resolved KO fixture
```

No new fixture column needed — the join is by **team name** (the KO fixture is `:editable`, so both
names are resolved). `Fifa.Players` builds a map `%{norm(team) => [%{name, position, goals}]}`.

## Architecture / components

```
Predictex.Fifa.Players (NEW)
  ├─ parse/1                pure: players.json + squads.json → %{norm(team) => [player maps]}
  │                         (player map: %{name, position, goals}; sorted goals-desc then name)
  ├─ for_team/2             pure: the squad list for one team name (via the map)
  └─ cache + refresh        a lightweight ETS/Agent cache populated by a worker

Predictex.Workers.PlayersSync (NEW, or fold into CohortSync's tick)
  └─ fetch players.json (+ squads.json) on the cron, repopulate the cache (goals change as
     matches play; squads are static). Stop-before-fetch not needed — it's cheap + always wanted.

PredictexWeb.MyPredictionsLive (modify)
  └─ the :editable KO card's "First scorer" section gains a "First Player To Score" button that
     opens an app-styled modal; the modal renders the fixture's two squads from Fifa.Players;
     a colocated hook does client-side search/toggle/select and writes the chosen name into the
     existing sr-only first_scorer_player input (same pattern as the side/booster toggles).
```

### Data fetch / cache

`players.json` is 408 KB and `stats.goals` changes as matches are played, so it needs periodic
refresh — but the **roster** is static. A `Workers.PlayersSync` (cron, e.g. `*/30` or hourly) fetches
`players.json` + `squads.json`, builds the `norm(team) => [players]` map, and stores it in an ETS
table / `Agent` the LiveView reads on mount. Source URL injectable for tests (mirrors
`:ko_ids_rounds_fun`). v1 may also just fetch-on-mount with a short TTL cache if a worker is
overkill — decide in the plan; the worker is the cleaner long-run shape.

### UI — the modal (app style, not FIFA blue)

Reuse the app's modal from `core_components.ex` (daisyUI), styled to match the existing KO card. The
modal, per the reference screenshot but in predictex's palette:

- Header: "Which player will score first?" + close.
- **Two-team toggle** (the fixture's `team1`/`team2`, with flags) — switches the list.
- **Search** box (client-side filter on `shortName`).
- A scrollable **list**: each row = `shortName` · **position** badge (GK/DEF/MID/FWD) · **goals** ·
  a select control. Plus a **"No first scorer"** row at the top (predict no scorer / 0-0).
- Selecting a player closes the modal and shows the pick on the card (e.g. "First scorer: Matheus
  Cunha"); the card's existing first-team toggle stays (a member may set both, or just the player).

**v1 scope:** team-toggle + search + goals + "No first scorer". **Defer to a polish pass:** position
filter chips and player photos (`players.json` has no image URLs — photos need a separate source).

### Wiring + the hook

The selection writes the chosen player's `shortName` into a sr-only
`name="picks[<fixture_id>][first_scorer_player]"` input — the exact field `parse_pick_rows/2` already
reads and `save_round_predictions/5` persists. So **no save-path or scoring change is needed for
v1**; the picker is purely a better input. The colocated JS hook (extend `RoundEntry` or a sibling
`PlayerPicker`) handles open/close, client-side search/toggle, and writing the sr-only input —
mirroring how `RoundEntry` already drives the side/booster toggles via sr-only inputs (so the
existing `phx-submit` field names and the save tests are untouched).

## Scoring

**v1:** unchanged — `Scoring.first_player_points/3` free-text `norm`-matches the stored name against
`fixture.first_scorer_player` (populated by openfootball, `openfootball.ex:50`). The picker just makes
the member's input typo-proof and canonical, so the match is far more reliable than hand-typed text.

**Follow-up (separate bead):** store the selected `fifaId` and match it exactly against the actual
scorer's `IdPlayer` from the FIFA `/detail` capture — removes name-normalisation fragility entirely.
Needs a `predictions.first_scorer_fifaid` migration + the capture-side id; out of scope for v1.

## Decisions (proposed — confirm in review)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Source the picker from `players.json` (static feed), join by **team name** | Verified available pre-match; no new fixture column; reuses `Crosswalk`. |
| 2 | Modal picker (not inline), reusing `core_components` modal, **app palette** | Matches the reference UX without 52 rows inline on a 4-up card grid; consistent with the app. |
| 3 | Selection sets the existing `first_scorer_player` field; **scoring stays free-text v1** | Ships day-one with zero save-path/scoring/migration change; the picker is a pure input upgrade. |
| 4 | v1 = team-toggle + search + goals + "No first scorer"; defer position-filter + photos | Smallest thing that matches the ask; photos need a source we don't have. |
| 5 | A `PlayersSync` worker refreshes the cache on the cron | `stats.goals` changes during matches; roster is static. (Fetch-on-mount+TTL is an acceptable v1 fallback — plan decides.) |
| 6 | `fifaId`-exact scoring is a **follow-up** (own bead), not v1 | Needs a migration + capture-side id; free-text scoring already works. |

## Testing

- `Fifa.Players.parse/1` (pure): players.json + squads.json fixtures → correct `norm(team) =>
  [players]`, sorted goals-desc, position decoded, FIFA-alias team join (e.g. "Bosnia and
  Herzegovina" → our "Bosnia & Herzegovina").
- `for_team/2`: returns a known team's squad; unknown team → `[]`.
- LiveView render (`@tag :native_ko`): the `:editable` KO card shows a "First Player To Score"
  control; opening it renders both squads (names + goals) + "No first scorer"; the two-team toggle
  switches lists.
- Selection → the sr-only `first_scorer_player` input carries the chosen name → `save_round` persists
  it → `Predictions.get_player_fixture_prediction` returns the player; a settled fixture with that
  scorer awards +10 (free-text match) — exercise the full chain.
- Worker/cache: `PlayersSync.perform` populates the cache from a stubbed feed; the LiveView reads it.
- Gate `mix precommit` green; no migration (v1); no new deps; `Crosswalk` reused, not duplicated.

## Non-goals / YAGNI

- **No** position filter or player photos in v1 (polish follow-up; photos need a source).
- **No** scoring/schema change in v1 (free-text already works; `fifaId`-exact is a separate bead).
- **No** group-stage picker (first-player is knockout-only by the scoring rules).
- **No** per-match lazy fetch — `players.json` is one static feed for all squads.

## Rollout

Additive; rides a normal deploy. Member visibility stays gated by `:native_ko_entry` (already on).
The `PlayersSync` cache must be warm before the picker renders usefully — the worker populates it on
boot/cron; a cold cache degrades to an empty list (the card still saves a blank first-player, exactly
as today). No flag needed.
