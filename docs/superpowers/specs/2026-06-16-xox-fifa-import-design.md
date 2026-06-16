# xox — FIFA prediction self-import (design)

**Date:** 2026-06-16 · **Issue:** `predictex-xox` (P2) · **Type:** feature
**Spike:** `docs/superpowers/research/2026-06-16-xox-fifa-import-spike.md` (read first)

## Problem

Members make their predictions on the official FIFA Match Predictor, not in predictex.
Today their picks reach the app only by an **admin transcribing screenshots** (`a02`,
`/admin/predictions`). That is toil and a bottleneck. `xox` lets each member **import their
own** FIFA picks themselves, with a preview-and-confirm gate, removing the admin from the
loop for the common case.

The spike confirmed the data is fully available from a stable authed JSON API behind a
FIFA-ID login + Akamai anti-bot shield — so the collection step **must** run inside the
member's own browser session (a bookmarklet). Scripted/server-side requests to the
prediction endpoints get `403`. The static reference JSON (`rounds.json`) is public and
server-fetchable.

## Scope (first cut)

**In:** group-stage **scoreline + booster** import, self-service per member.
- Rounds 1–3 (the three group rounds).
- Fields: `homeScore`/`awayScore` → `home_goals`/`away_goals`, `booster` → `booster`.
- Bookmarklet + `/import` preview-and-confirm LiveView + paste-JSON fallback.

**Out (deferred — separate future issue):**
- Knockout rounds (4–8) and first-scorer matching (`firstSquadScored`/`firstPlayerScored`).
  The knockout schema is clear but **unpopulated** until those rounds open (the spike saw
  `predictions: []`), so it cannot be tested yet, and it adds fuzzy cross-source player-name
  matching. Defer until a populated sample exists.
- Any admin/bulk pull. The per-FIFA-account auth boundary forbids it — import is per-member.

## Decisions (settled in brainstorming)

1. **Scope:** group-stage scoreline + booster only. *(deferred: knockout / first-scorer.)*
2. **Transport:** bookmarklet hands the payload to **our origin** via URL fragment; import runs
   inside the member's authenticated predictex session with a preview-and-confirm gate.
   *(rejected: per-member token + cross-origin CORS POST — more moving parts, no preview.)*
3. **Delivery:** an authenticated `/import` page carries instructions, the draggable bookmarklet,
   and a **paste-JSON fallback** for FIFA/Akamai drift. *(rejected: minimal endpoint only.)*
4. **Crosswalk location:** **server-side**; the bookmarklet is thin. Payload carries
   `{round, matchId}`, not resolved names. The server fetches `rounds.json` (reusing
   CohortSync's confirmed public fetch) and resolves `{round, matchId} → (date, teams) →
   Fixture` (composite key — see `Fifa.Import` for why the `round` must be part of the key).
   *(rejected: client-side resolution — fatter, more fragile, untestable bookmarklet.
   Tradeoff accepted: import depends on `rounds.json` at request time, already a standing
   dependency via CohortSync.)*

## Architecture / data flow

```
[ member's browser @ play.fifa.com ]  — bookmarklet (thin: collect + handoff) —
   for round in 1..3:
     GET /api/en/match-predictor/prediction/show/{round}   (cookies + Akamai = 200)
   await ALL responses, then build payload:
     [{round, matchId, homeScore, awayScore, booster}]
   open  https://wc-predict.davewil.dev/import#<base64url(json)>
                          │
[ member's browser @ predictex, logged in ]   ▼
   /import  (ImportLive, :require_authenticated_player)
     JS hook reads location.hash → pushes payload to the LiveView over the authed socket
     server fetches rounds.json → builds {round, matchId} → (date, team1, team2) map
     Fifa.Import.plan(payload, rounds, fixtures) [PURE] →
        {matched: [%{fixture, home_goals, away_goals, booster, round_id}], unmatched: [%{row, reason}]}
     PREVIEW renders matched rows + unmatched rows (with reason)
     on "Confirm import" → write per round via Predictions.admin_save_round_predictions/3
                           (player_id = current member)
```

### Why a URL fragment + JS hook (not a cross-origin POST)

- The browser **never sends the fragment to the server**, so nothing is logged or persisted
  server-side until the member confirms (honours the spike's privacy note: nothing centralised
  without member action).
- A small LiveView JS hook reads `location.hash`, base64url-decodes it, and pushes it into the
  LiveView over the **already-authenticated same-origin socket** — so there is no cross-origin
  request and no CSRF token to forge. A cross-origin form POST from fifa.com would be rejected
  by Phoenix's CSRF protection; the fragment path sidesteps it entirely.
- The hook clears the hash (`history.replaceState`) after reading, so the payload doesn't linger
  in the address bar / browser history.

## Components

### New — `Predictex.Fifa.Crosswalk` (pure, extracted)
The `{utc_date, unordered team-set}` match key, the verified FIFA↔openfootball `@aliases`
table, `norm/1`, and `utc_date/1` — **extracted from `Fifa.Cohort`** so `Cohort` and the new
import share one matching authority (one place to fix an alias divergence; ties to `c9s`).
- `index_fixtures(fixtures) :: %{key => Fixture}`
- `match_key(date_or_iso, team_a, team_b) :: {Date.t() | nil, MapSet.t()}`
- `norm/1`, `@aliases` (moved verbatim — no behaviour change).
- **Correctness:** the key is `{date, team-set}`, NOT date-with-names-as-tiebreaker. Group
  stage runs **multiple matches per calendar date**, so date alone collides — the team-set is
  essential. `Cohort.plan/3` is refactored to call `Crosswalk` and must keep its current tests
  green (pure refactor, no behaviour change).

### New — `Predictex.Fifa.Import` (pure)
- `plan(payload_rows, rounds, fixtures) :: %{matched: [...], unmatched: [...]}`.
  - **`rounds.json` lookup is keyed by the composite `{round, matchId}`, NOT a flat `matchId`
    map.** Each payload row carries its `round`; the spike left "does `tournaments[].id` reset
    per round?" unresolved (`matchStats.json` is keyed 1…72 across the 72 group matches, which
    *suggests* global numbering — but we do not rely on that). A flat map would, if ids reset,
    resolve round 2's `matchId:1` to round 1's match and write a real scoreline onto the **wrong
    real fixture** — silent corruption the date+team-set key cannot catch (the mis-resolved
    record carries its own consistent date/teams). Scoping by `{round, matchId}` is correct if
    ids reset, harmless if global, and degrades a wrong client `round` to a safe `:no_fixture`
    miss rather than a wrong hit. **This is the producer/consumer data contract (CLAUDE.md):
    the lookup key must be unique in normal operation.**
  - For each payload row: resolve `{round, matchId}` → `(homeSquadName, awaySquadName, date)`
    from the round's `tournaments[]`; build the `Crosswalk` key; find the Fixture.
  - Group-stage filter: only rounds 1..3 are kept; any row with `round ∉ 1..3` is dropped into
    `unmatched` with reason `:out_of_scope` (defensive — the bookmarklet only sends 1..3, but
    the server must not trust the client).
  - **Matched** entry: `%{fixture_id, team1, team2, home_goals, away_goals, booster, round_id}`.
    `team1`/`team2` are for **preview display only**; the row handed to the write path is
    stripped to exactly `%{fixture_id, home_goals, away_goals, booster}` (see Write path —
    `save_round_row/3` reads `row.fixture_id` and pattern-matches `home_goals`/`away_goals`).
    Orientation: payload `homeScore`/`awayScore` map to the fixture's `team1`/`team2` using the
    same first-listed-is-home convention + logged swap as `Cohort.orient/3`.
  - **Unmatched** entry: `%{round, matchId, reason}` where reason ∈ `:unknown_match_id` (no
    `{round, matchId}` in rounds.json), `:no_fixture` (no Fixture for that date+team-set),
    `:out_of_scope` (round ∉ 1..3), `:invalid` (missing/nil scores). Reason surfaced in preview.
  - Pure: no DB, no network. The LiveView/edge supplies `rounds` and `fixtures`.

### New — `Predictex.Fifa.Reference` (or reuse) — server fetch of `rounds.json`
Extract `CohortSync.get_json/1` into a shared `fetch_rounds/0` (returns `{:ok, rounds} |
{:error, reason}`), reused by both `CohortSync` and the import edge. Injectable for tests via
`:fifa_reference_fun` (mirrors `:cohort_source_fun`) so import tests are network-free.

### New — `PredictexWeb.ImportLive` (`/import`, `:require_authenticated_player`)
- **Dumb LiveView (CLAUDE.md rule):** holds the decoded payload + the `Fifa.Import.plan/3`
  result in assigns and renders. No scoring, no `try/raise` — validation happens in the pure
  core before data reaches it.
- Receives payload two ways: (a) the JS hook pushing the decoded fragment, (b) the paste-JSON
  textarea (`phx-submit`). Both feed the same `plan/3`.
- States: `:awaiting` (instructions + bookmarklet + paste box) → `:preview` (matched +
  unmatched lists, **explicit "this will overwrite your existing picks for these fixtures"**
  notice) → `:done` (counts: imported / skipped / unmatched).
- On confirm: group matched rows by `round_id`, call
  `Predictions.admin_save_round_predictions(player_id, round_id, rows)` per round (player_id =
  `current_scope` member). That gives a per-round transaction and the existing clean
  one-booster-per-round semantics. Every FIFA row has a scoreline, so the skip-on-blank /
  rollback-on-booster-on-blank edges do not fire — but the code path is reused, not
  re-implemented.

### New — the bookmarklet (static asset + page snippet)
- Thin: loop rounds 1..3, `fetch(prediction/show/{r})` with `credentials: "include"`, **await
  all** responses, flatten `success.predictions` into `[{round, matchId, homeScore, awayScore,
  booster}]`, base64url-encode, `window.open(IMPORT_URL + "#" + encoded)`.
- Served from the `/import` page as a draggable link + copy-paste source. Minified inline.

### Router
Add to the `:require_authenticated_player` live_session:
`live "/import", ImportLive, :index`.

## Write path & idempotency

- Reuses `Predictions.admin_save_round_predictions/3` (no kickoff lockout — the FIFA pick is
  the proof, same justification as admin entry).
- **Verified row contract (`save_round_row/3`, predictions.ex:169-186):** rows handed in are
  stripped to exactly `%{fixture_id, home_goals, away_goals, booster}` with **atom keys** —
  the function reads `row.fixture_id` directly and pattern-matches `home_goals`/`away_goals`
  for its skip/booster-on-blank cases, then passes the row into `Prediction.changeset` (which
  whitelists via `cast`, so stray keys would be ignored — but we don't pass any). `round_id`
  is set by the function from its 2nd arg, so it is **not** included in the row.
- **Overwrite semantics:** re-importing replaces the member's picks for the matched fixtures.
  Idempotent — running it twice yields the same state. The preview states this explicitly
  before the member confirms (a member may already have admin-transcribed picks).
- **Booster-clear is round-wide, the matched set is a subset — edge to surface, not hide.**
  `admin_save_round_predictions/3` clears *every* booster for `{player_id, round_id}` up front,
  then re-applies from the passed rows. So if the member's FIFA booster sits on a match we
  **couldn't** import (unmatched — e.g. an alias gap), or on a fixture not in the matched
  subset, the round-wide clear would leave them with **no booster that round** — and on
  import-over-admin-entry it would wipe a previously-transcribed booster. **Decision:** the
  preview makes the booster destination explicit and shows a **prominent warning when the
  member's booster falls on an unmatched row** ("your booster is on a match we couldn't import;
  importing this round will leave you without a booster — fix the unmatched row or proceed
  knowingly"). Import is thus an honest **round-level overwrite**, never a silent booster loss.
  *(Confining the clear to the matched subset is rejected for the first cut: it diverges from
  the proven admin path and complicates the one-booster-per-round invariant; revisit only if
  the warning proves insufficient.)*

## Error handling

- Fragment decode failure / malformed JSON → `:awaiting` state with an inline error; never
  crashes the LiveView (handled in the pure decode boundary).
- `rounds.json` fetch failure at import time → preview shows a "couldn't reach FIFA reference
  data, try again or use paste-JSON" message; no partial write.
- Unmatched rows never block matched rows — the member confirms the matched set; unmatched are
  listed with reason for transparency.
- **Login redirect can drop the fragment.** If the member isn't logged into predictex when the
  bookmarklet opens `/import#<payload>`, the `:require_authenticated_player` 302 to
  `/players/log-in` may lose the fragment (the server never sees it; browser fragment-carry
  across redirects is inconsistent). Mitigations, in order: (1) the `/import` page tells members
  to **log in first**; (2) paste-JSON covers a lost payload (re-run the bookmarklet after
  logging in, or paste); (3) optional hardening — the JS hook stashes the decoded payload to
  `sessionStorage` on read and restores it after an auth round-trip. Low severity (15-person
  audience, paste-JSON fallback), so (1)+(2) ship first; (3) only if it bites.

## Testing

**Pure cores (unit, network-free, the bulk of coverage):**
- `Fifa.Crosswalk`: key construction, alias normalisation, team-set unordering, date parsing.
  Existing `Cohort` tests must stay green after the extraction (regression guard).
- `Fifa.Import.plan/3`: matched/unmatched partition; each `reason`
  (`:unknown_match_id`/`:no_fixture`/`:out_of_scope`/`:invalid`); out-of-scope knockout drop;
  multiple-matches-per-date disambiguation by team-set (the collision a date-only key gets
  wrong).
- **Composite-key correctness (must-pass):** if `tournaments[].id` repeats across rounds, a row
  `{round: 2, matchId: 1}` resolves to round 2's match, never round 1's — assert a same-`matchId`
  pair in different rounds maps to the two distinct fixtures (the silent-corruption guard).
- **Scoreline orientation (must-pass, not just "swap"):** when FIFA's home/away ordering differs
  from the fixture's `team1`/`team2`, assert `home_goals`/`away_goals` follow the **FIFA home
  team into the correctly-oriented fixture column** (a missed swap inverts the scoreline — writes
  the wrong result, unlike Cohort where it only swaps symmetric percentages).
- **Write-contract guard:** the row handed to `admin_save_round_predictions/3` has exactly
  `%{fixture_id, home_goals, away_goals, booster}` (atom keys); assert `save_round_row/3`
  upserts it (no `:skipped`/`:booster_on_blank` surprise — every FIFA row has a scoreline).
- Payload decode boundary: valid base64url, malformed, empty, oversized.

**LiveView (integration):**
- Mount `/import` requires auth (redirect when logged out).
- Paste-JSON → preview → confirm writes predictions for the **current member** (full flow,
  per CLAUDE.md: test page → action → result, not isolated mounts).
- Overwrite: importing over existing picks replaces them; booster moves correctly.
- Unmatched rows render with reason and do not block the matched write.
- **Booster-on-unmatched warning:** when the payload's boosted match is unmatched, the preview
  shows the prominent warning and confirming still proceeds (round-level overwrite, no silent
  loss).

**Manual real-session validation (explicit acceptance criterion — CI cannot cover this):**
The assembled bookmarklet running in a live authenticated FIFA session is the one untestable
artifact. Before `xox` is called done, the operator must run it end-to-end from their own
FIFA login into a `/import` preview and confirm a write. Named unknowns to check:
- `window.open` popup-blocker behaviour (may need the bookmarklet to be a user gesture).
- URL fragment size with ~72 rows (well within browser limits, but verify).
- Awaiting **all** round fetches before opening the tab (no race / partial payload).

## Risks & mitigations

- **Akamai / endpoint drift:** FIFA can change the anti-bot scheme or `prediction/show` shape.
  Mitigation: paste-JSON fallback; admin entry (`a02`) remains the guaranteed path. Import is a
  *bonus*.
- **Name divergence (alias gaps):** a new FIFA spelling not in `@aliases` → `:no_fixture`.
  Mitigation: surfaced as an unmatched reason; one-line fix in the shared `Crosswalk` alias
  table (ties to `c9s`).
- **Crosswalk regression:** extraction must not weaken the key to date-only. Guarded by the
  multiple-matches-per-date test and the retained `Cohort` tests.

## Out of scope / future

- Knockout import + first-scorer matching (`firstSquadScored`/`firstPlayerScored`) — separate
  issue once those rounds populate.
- Server-side import token + CORS path — not needed given the fragment handoff.

## Security / privacy

- Bookmarklet reads **only the member's own** predictions from their own session; uses the live
  session, persists no FIFA tokens/cookies, hands over only prediction JSON.
- Payload travels in the URL fragment (not sent to the server) until the member confirms; the
  hook clears the hash after reading. The write happens within the member's own predictex
  session — no privilege escalation, no admin involvement.
