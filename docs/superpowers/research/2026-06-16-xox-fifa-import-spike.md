# Spike report — FIFA Match Predictor import (`predictex-xox`)

**Date:** 2026-06-16 · **Issue:** `predictex-xox` · **Type:** discovery spike (read-only)
**Question:** *What prediction data can we actually extract from FIFA.com's Match Predictor, and what does that mean for the import design?*

## TL;DR

- **Outcome A — clean authed JSON API.** A member's predictions come from a single stable
  endpoint: `GET https://play.fifa.com/api/en/match-predictor/prediction/show/{round}`,
  returning a `{success: {predictions: [...]}, errors: []}` envelope.
- **Every field we need is present:** `homeScore`/`awayScore` (scoreline), `booster`, and —
  for knockout rounds — `firstSquadScored`/`firstPlayerScored`. No DOM scraping, no reading a
  JS store.
- **Why the bookmarklet is mandatory (confirmed):** the predictor is behind a FIFA ID login
  **and** an Akamai anti-bot shield. Scripted/server-side requests get `403`; a script running
  *inside the member's validated browser session* (bookmarklet/console) succeeds. There is no
  server-side path.
- **The work is integration, not data availability.** Three real challenges: the FIFA
  `matchId` → our `Fixture` crosswalk, cross-origin transport (fifa.com → our app), and
  knockout name-matching. Group-stage import (scoreline + booster) has none of the hard parts
  and should ship first.

Evidence below is tagged **[confirmed]** (directly observed), **[inferred]** (reasoned from
observation), or **[todo]** (still to verify).

---

## Method

1. **Attempted: drive the predictor via the Chrome DevTools MCP.** Navigated a DevTools-
   controlled Chrome to `play.fifa.com/match-predictor/match`. The logged-out predictor
   rendered (past Round 1 matches with results + "Popular Picks" percentages).
2. **Blocker [confirmed]:** sign-in could not complete — Google OAuth (and FIFA's anti-bot)
   **refuse authentication in an automation-controlled browser** (CDP flags detected). This is
   a hard wall for any driven-browser approach and reinforces the bookmarklet model.
3. **Pivoted: read-only console probes in the operator's own authenticated browser.** Three
   successive snippets: (a) locate where predictions live (storage / window / API), (b) inspect
   the cached user object + discover real endpoints via the browser performance log, (c) fetch
   the prediction endpoint and dump the (identity-redacted) shape. All read-only; identity
   fields masked before paste-back.

---

## Findings

### 1. Predictor architecture [confirmed]

- **React SPA** (Sentry `sentry.javascript.react/9.2.0` seen in beacons; `__SENTRY__` global).
- **Auth:** FIFA ID via Google OAuth (`accounts.google.com`). `GET /api/en/user` → `403`
  logged-out, `200` logged-in.
- **Anti-bot:** Akamai Bot Manager — `ak_a` / `ak_ax` tokens in `localStorage` and obfuscated
  sensor POST beacons to `play.fifa.com/FYVNeb/XQQN/…` (`201`). **This is the `403`-on-scripted-
  requests mechanism the issue references.**
- **No global state store** [confirmed]: `window` exposes only native props + `__SENTRY__` /
  Adobe `__satelliteLoaded` / `__tcfapi`. React state is encapsulated → **reading an in-page
  store (outcome B) is not viable.**
- **localStorage scheme** [confirmed]: app data keyed `/(match-predictor)<thing>-1` —
  `…user-1`, `…is_authenticated-1`, `…mp_tutorial-1`. **No predictions cached in localStorage.**

### 2. Data is split into two tiers [confirmed]

**Auth-free static reference JSON** (200 while logged out), under
`https://play.fifa.com/json/match_predictor/`:

| File | Likely contents |
|------|-----------------|
| `rounds.json` | round + match structure (fixtures, `matchId` ↔ teams/date) — **[todo] not yet read** |
| `squads.json` | teams / squads (`firstSquadScored` resolution) — **[todo]** |
| `players.json` | players (`firstPlayerScored` resolution) — **[todo]** |
| `matchStats.json` | results + (likely) the "Popular Picks" cohort % — **[todo]** |
| `message_banner.json`, `checksums.json`, `poc.json` | app meta |

> Also `https://api.fifa.com/api/geo/esigeo.json` (geo). A console `fetch()` of the `/json/…`
> reference files returned an HTML shell in one attempt, but that was while the page had
> navigated to the Google origin — **[todo] whether an in-session console fetch of the static
> JSON is Akamai-challenged is unverified.** The bookmarklet may need to read reference data the
> app has *already* loaded rather than re-fetch it.

**Auth-gated API** (`/api/en/…`, `{success, errors}` envelope, cookie + Akamai gated):

| Endpoint | Purpose |
|----------|---------|
| `GET /api/en/user` | profile only — `{success: {user: {...}}}`; **no predictions** [confirmed] |
| **`GET /api/en/match-predictor/prediction/show/{round}`** | **the member's predictions for a round** [confirmed] |
| `GET /api/en/match-predictor/leagues` | the member's leagues |
| `GET /api/en/match-predictor/ranking/league/{leagueId}` | league standings |
| `GET /api/en/match-predictor/ranking/gamebar?round={r}&user={userId}` | per-round ranking |
| `GET /api/en/prompt?game=match_predictor` | UI prompt state |

### 3. The prediction read model [confirmed]

`GET /api/en/match-predictor/prediction/show/1` (a group round, real data, identity-free):

```jsonc
{ "success": { "predictions": [
  {
    "predictionId": 3181747,   // FIFA internal id — ignore
    "matchId": 1,              // FIFA match id (sequential) — needs crosswalk to our Fixture
    "homeScore": 2,            // -> home_goals
    "awayScore": 0,            // -> away_goals
    "firstSquadScored": null,  // knockout only -> first_scorer_side (squad -> home/away)
    "firstPlayerScored": null, // knockout only -> first_scorer_player (player id -> name)
    "noneSquad": false,        // "predicted no first-scoring squad"
    "nonePlayer": false,       // "predicted no first scorer"
    "booster": true,           // -> booster (same one-per-round concept)
    "stats": { "OC":10,"HG":5,"AG":5,"GD":5,"SB":5,"RB":0 }, // FIFA's own scoring — ignore
    "matchScore": 60           // FIFA's computed total — ignore
  }
]}, "errors": [] }
```

- **Knockout round 4 (`prediction/show/4`) returned `predictions: []`** [confirmed] — knockout
  rounds aren't open/predicted yet, so populated `firstSquadScored`/`firstPlayerScored` values
  are **[todo]** (schema clear; live shape unverified until those rounds open).
- FIFA's own `stats` even includes a risky-bonus (`RB`) component, mirroring our risky bonus —
  interesting but unused (we compute our own scoring).

### 4. Field mapping → our `Prediction` contract

| FIFA field | Our field | Status |
|------------|-----------|--------|
| `homeScore` / `awayScore` | `home_goals` / `away_goals` | direct [confirmed] |
| `booster` | `booster` | direct [confirmed] — one-per-round aligns |
| `firstSquadScored` | `first_scorer_side` (`:home`/`:away`) | knockout; resolve squad → side [inferred] |
| `firstPlayerScored` | `first_scorer_player` (string) | knockout; resolve player-id → name [inferred] |
| `noneSquad` / `nonePlayer` | → nil first-scorer | [inferred] |
| `matchId` | `fixture_id` | **crosswalk required** [confirmed problem] |
| `stats` / `matchScore` / `predictionId` | — | ignore [confirmed] |

---

## The three integration challenges

### A. `matchId` → `Fixture` crosswalk (the core problem)

FIFA's `matchId` (1, 2, 3 …) is opaque and **not present in openfootball** (our fixture source,
keyed by `external_ref` like `"2026-06-11 Mexico v South Africa"`). Options:

1. **Resolve in the bookmarklet, match by teams+round on our side (recommended [inferred]).**
   The bookmarklet has FIFA's reference data in-session, so it maps `matchId` →
   `(round, homeTeam, awayTeam)` and sends *those*; `/api/import` matches to a `Fixture` by
   round + team names. Keeps FIFA's opaque ids out of our domain; ties into `predictex-c9s`
   (team-name normalization).
2. **Store FIFA `matchId` on `Fixture`.** Add a column, populate via a one-off mapping. Tighter
   match, but our fixtures come from openfootball which has no FIFA id — needs its own crosswalk
   to populate, so it just moves the problem.

→ **Decision for design:** likely (1). Requires confirming `rounds.json`'s `matchId` ↔ team
mapping **[todo]** and a team-name normalization step (FIFA names vs openfootball names).

### B. Cross-origin transport (fifa.com → our app)

The bookmarklet runs on `play.fifa.com`; our app is `wc-predict.davewil.dev`. A direct
cross-origin POST won't carry the member's predictex session cookie (different origin /
SameSite). Options:

1. **Hand the payload to our origin (recommended [inferred]):** bookmarklet collects + encodes
   the predictions, then opens `https://wc-predict.davewil.dev/import` with the data (URL
   fragment / form POST / `postMessage`). The member is logged into predictex there, so a
   **preview-and-confirm** import runs inside their own session. No cross-origin auth, and a
   human confirmation gate before anything is written.
2. **Per-member import token + CORS.** Member copies a token from predictex into the bookmarklet;
   `/api/import` accepts token-auth with CORS. More moving parts; no natural preview step.

→ **Decision for design:** likely (1) — simpler and gives a confirmation gate.

### C. Knockout name-matching (defer)

`firstPlayerScored` is a FIFA player-id; our `first_scorer_player` is a **name string** matched
(normalized) against openfootball's actual first-scorer name. Cross-source player-name matching
is fuzzy and only relevant in knockout rounds. **Group-stage import (scoreline + booster) has no
name-matching at all**, so ship that first and layer knockout when those rounds open and we can
capture a populated sample.

---

## Recommended architecture (for the design session)

```
[ member's browser, logged into play.fifa.com ]
  bookmarklet:
    for round in 1..8:
      GET /api/en/match-predictor/prediction/show/{round}   (cookies + Akamai session = 200)
    resolve matchId -> (round, home, away) via FIFA reference data
    build payload: [{round, home, away, home_score, away_score, booster, first_*}]
    -> open  https://wc-predict.davewil.dev/import  with payload
                              |
[ member's browser, logged into predictex ]      v
  /import (authenticated as the member):
    match each row to a Fixture (round + team names, normalized)
    PREVIEW: show resolved fixtures + picks + any unmatched rows
    on confirm -> Predictions.admin_upsert_prediction-style write (player = current member)
```

- **Self-service per player** [confirmed requirement] — each member imports their own picks; the
  per-FIFA-account auth boundary forbids an admin bulk-pull.
- Reuses the `mt6` Oban substrate if any server-side async is wanted, and the existing
  `admin_upsert_prediction/1` write path (no kickoff lockout — same as admin entry).
- **Paste-JSON and manual fallbacks** (from the issue) remain as graceful degradation if the
  bookmarklet breaks (Akamai/endpoint change).

---

## Open questions / TODO before/at design

- **[todo]** Read `rounds.json` / `squads.json` / `players.json` shapes — confirm `matchId` ↔
  teams/round and squad/player id resolution. (Capture in a follow-up console probe.)
- **[todo]** Capture a **populated knockout** `prediction/show/{round}` once those rounds open —
  verify `firstSquadScored` / `firstPlayerScored` value formats.
- **[todo]** Does `matchStats.json` carry per-outcome **cohort %** (home/draw/away) we need for
  the risky bonus, or only per-scoreline "Popular Picks"? If usable, the bookmarklet could also
  feed cohort data — a bonus that reduces admin entry (relates to `a02` cohort entry).
- **[todo]** Is an in-session console/bookmarklet `fetch()` of the static `/json/…` reference
  files Akamai-challenged? If so, read what the app already loaded instead of re-fetching.
- **[todo]** Round numbering / count: assumed `1..8` (3 group + 5 knockout) from the UI tabs +
  `rules.md`; `show/1` (group) confirmed, `show/4` (Round of 32) inferred.
- Team-name normalization map (FIFA ↔ openfootball) — overlaps with `predictex-c9s`.

## Risks

- **Akamai / endpoint drift:** FIFA can change the anti-bot scheme or the `prediction/show`
  shape mid-tournament. Mitigation: keep paste-JSON + manual entry fallbacks; the import is a
  *bonus* path (admin entry `a02` remains the guaranteed one).
- **Name-matching errors** (knockout): wrong fixture/player match → wrong scoring. Mitigation:
  preview-and-confirm gate; group-first.

## Security / privacy notes

- The bookmarklet reads **only the member's own** predictions from their own session; nothing is
  centralised without their action.
- **Do not** persist FIFA tokens/cookies; the bookmarklet uses the live session and hands over
  only prediction JSON.
- Spike capture used identity-masked, read-only snippets; the operator's FIFA `userId` /
  `leagueId` / email are deliberately **not** recorded here (referenced as `{userId}` etc.).
- The confirm-and-import step writes within the member's own predictex session — no privilege
  escalation, no admin involvement.

## Verdict

`xox` is **feasible and smaller than feared.** The data is fully available via a stable authed
JSON API; the engineering is a `matchId`→fixture crosswalk + a cross-origin handoff with a
preview gate, with knockout name-matching deferred. Recommend proceeding to a design session for
the three forks above, scoping the first cut to **group-stage scoreline + booster import**.
