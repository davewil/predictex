# Design — Mum-proof FIFA import guide (`predictex-4ar`)

**Date:** 2026-06-16 · **Issue:** `predictex-4ar` · **Type:** feature
**Depends on:** `predictex-xox` (import core, `/import`, `Fifa.Import.plan/3`) — code-complete.
**Defers to:** `predictex-i9k` (knockout import).

## Problem

The `/import` flow built for `xox` is developer-shaped. Its onscreen copy says "Drag this
button to your bookmarks bar" (desktop-only) and the fallback is "run it in the browser console
and paste the JSON it prints here" — jargon a non-technical user cannot follow, and a console
path that is **impossible on a phone**. Most of the group will be on mobile (WhatsApp). The bar
is the "mum test": a non-technical 75-year-old should complete an import unaided.

## What the spike established (ground truth, 2026-06-16)

These facts are load-bearing for the design and were verified live, not assumed:

1. **No server-side path exists, ever.** A member's predictions come only from
   `GET /api/en/match-predictor/prediction/show/{round}`, behind FIFA-ID login **and** Akamai
   anti-bot. Scripted/server requests get `403`. (xox spike.)
2. **A top-level *user navigation* to that URL returns the raw JSON — on BOTH desktop and
   Android — when logged in.** This is the key unlock: it is the user's own validated session,
   not a "scripted request", so Akamai does not challenge it. (Verified this session: desktop
   `200` + JSON; Android `200` + identical JSON. An earlier Android `404` was a path-slug typo,
   not a block.)
3. Each round call returns one matchday (~24 predictions). Group stage = rounds 1–3 = 72
   matches. Knockout rounds are empty until they open (`i9k`).
4. The raw envelope is `{"success":{"predictions":[{matchId,homeScore,awayScore,booster,…}]},"errors":[]}`.
   It does **not** carry the round number — round is implied by *which* `/show/{r}` URL produced
   it. Any paste UI must therefore label its input by round and inject that round itself.

### The constraint, stated honestly

API-source + mobile + zero-setup is an over-constrained triangle — the browser security
boundary (code/requests in a logged-in session) is exactly what makes this fiddly. We cannot
*eliminate* friction; we choose *where it lands*:

- **One-time setup, then ~one tap/use** — bookmarklet (desktop drag is trivial; mobile install
  is the clunk the issue complains about).
- **Zero setup, friction every use** — tap link → Select All → Copy → paste (works on both
  platforms; N copy-pastes).

Group-stage import is essentially a **once-per-tournament** action, so per-use friction is
cheap and up-front install friction is not. That asymmetry decides the mobile path.

## Design

### Platform-aware `/import` — show the right flow only

`ImportLive.mount/3` classifies the request as `:mobile | :desktop` from the `user-agent`
(mobile = UA matches `Mobi|Android|iPhone|iPad`). The user never chooses a path.

**Implementation note (gotcha):** `get_connect_info(socket, :user_agent)` is only populated on
the *connected* (websocket) mount, returns `nil` on the first disconnected HTTP render, and
requires `:user_agent` to be listed in the endpoint's `socket "/live"` `connect_info`. To avoid
a flash of the wrong flow, the plan should resolve the UA on the static render — read it from
the `Plug.Conn` request header and pass it through the session (or a plug-set assign) — and fall
back to `get_connect_info/2` on reconnect. Default platform when UA is absent: `:mobile` (the
harder-to-misuse path, and the majority). Confirm the `connect_info` entry exists before relying
on it.

#### Desktop — one-tap bookmarklet (relabelled)

Keep the existing bookmarklet mechanism (`import_live.ex:195`); it works and a desktop drag is
easy. Changes are copy-only:

- Button label → **"Import my picks"** (never "bookmarklet").
- Numbered, plain-language steps: (1) drag this button up to your bookmarks bar, (2) open FIFA
  and sign in, (3) click **Import my picks**, (4) check what we found and confirm.
- The console-fallback line (`import_live.ex:122–124`) is **deleted**.

#### Mobile — guided copy-paste, no install, progressive reveal

The mobile branch leads with this (the bookmarklet is *not* shown as the primary path on
mobile; an optional "advanced" disclosure may mention it):

One round visible at a time, and **each round confirms and writes to the DB on its own**
(see "Persistence" below — this is not just UX, it is what makes the flow survive mobile tab
discards). For Round N:

1. **"Tap to open your Round N picks"** — a link to
   `https://play.fifa.com/api/en/match-predictor/prediction/show/N`, `target="_blank"`. FIFA
   renders the user's picks as text (they are logged in).
2. Plain instruction with a `[screenshot: …]` slot: **"Press and hold the text → Select all →
   Copy."**
3. **"Come back here and paste below."** A single textarea, labelled "Round N".
4. On paste + submit, **this round only** is validated and previewed inline. The user confirms,
   we **write Round N immediately** (`admin_save_round_predictions(player_id, round_id, rows)`),
   show **"Round N saved ✓"**, and only then reveal Round N+1. After Round 3 is saved, show the
   final success state.

Rationale for progressive reveal (chosen over three-boxes-at-once): one instruction on screen
at a time is gentler for a non-technical user and makes "where am I?" unambiguous.

#### Persistence — the flow must survive a tab discard

The mobile flow *mandates* leaving predictex (to FIFA) and returning, once per round. Mobile
browsers aggressively discard backgrounded tabs; when that happens the LiveView socket closes,
the process dies, and on return `mount/3` runs fresh with empty assigns. **Therefore round
progress must not live in socket assigns.** Each round is an independent
paste → preview → confirm → **DB write** cycle, so a confirmed round is durable in the database,
not in volatile process state. If the tab is discarded after Round 1 is confirmed, the user
returns, re-mounts, and Round 1 is already saved (writes are idempotent upserts via the existing
path). This is the specific reason the design does **not** accumulate three rounds for one final
confirm.

On re-mount we may optionally read the player's already-saved rounds to resume at the right step
("Rounds 1–2 already done — paste Round 3"); if that adds complexity, the safe fallback is to
restart at Round 1, and re-confirming a saved round is harmless (idempotent). Decide during
planning; correctness does not depend on it.

> Desktop is unaffected: the bookmarklet delivers all three rounds in a single URL fragment
> (one `mount`, no round-trips), so it keeps the single preview → single confirm that writes all
> rounds. Only the mobile multi-trip flow needs per-round writes.

#### Escape hatch — screenshot → admin (any platform, the literal mum)

A persistent, plain-language link at the bottom of both flows: **"Stuck? Take a screenshot of
your FIFA picks and send it to <admin> — they'll add them for you."** This routes to the
existing admin entry flow. Zero technology on the user's side; guarantees nobody is locked out.
No new code beyond the copy + (optionally) a `mailto:`/WhatsApp deep link.

### Data path — teach the paste to swallow FIFA's raw envelope

The pure core (`Fifa.Import.plan/3`, `to_write_rows/1`) and the preview/confirm gate are
**unchanged** — they already validate and orient, and are the safety net for any bad paste.

New, at the edge (`ImportLive` + a small pure helper):

- A pure function `Fifa.Import.rows_from_envelope(decoded, round)` that takes a decoded FIFA
  envelope (or a bare predictions list) plus a known round integer and returns
  `{:ok, rows}` / `{:error, :bad_envelope}`, where each row is
  `%{"round" => round, "matchId" => …, "homeScore" => …, "awayScore" => …, "booster" => …}` —
  exactly the shape `plan/3` already consumes. It tolerates both `{"success":{"predictions":[…]}}`
  and a top-level `[…]` array.
- `handle_event("paste", …)` is parameterised by the **current round** (socket assign tracking
  which round is in progress), decodes, calls `rows_from_envelope/2`, and runs `plan/3` over
  **just that round's** rows to build the inline preview. On confirm, that round is written to
  the DB; nothing is held across rounds (see Persistence). The "current round" assign is the
  only volatile state, and it is reconstructable from what is already saved (or simply restarts
  at Round 1).
- The base64 fragment/bookmarklet path (`handle_event("payload", …)`) is unchanged — the
  bookmarklet already emits `round`-tagged rows for all rounds at once, and keeps the single
  preview → single confirm (which writes every round via `to_write_rows/1`'s `round_id` grouping).

### Jargon purge (issue hard rule)

The words **"bookmarklet", "JSON", "console"** must not appear in any user-facing string.
Audit every string in `ImportLive.render/1` and helpers. Error copy too: e.g.
`import_live.ex:35` ("paste the JSON the bookmarklet produced") → "We couldn't read that —
paste exactly what FIFA showed you."

### Confirmation state

Reuse the `:done` step (`import_live.ex:169`), reworded warmly: **"Your picks are in ✅"** with
the count and a button to **See my predictions**. Keep the `errors > 0` note but in plain words.

## Components & boundaries

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `Fifa.Import.rows_from_envelope/2` (new, pure) | raw FIFA envelope + round → `plan/3` rows | none |
| `Fifa.Import.plan/3`, `to_write_rows/1` (unchanged) | validate/orient/group | `Crosswalk` |
| `ImportLive` (edit) | platform detect; render desktop vs mobile vs escape; per-round paste accumulation; preview/confirm | `Import`, `Reference`, `Tournament`, `Predictions` |

## Error handling

- Unreadable paste → friendly inline error, no crash; user can retry the same round.
- Reference fetch failure (`Reference.fetch_rounds/0`) → existing friendly message, retry.
- Unmatched rows → existing preview list with plain-language reasons (`reason_text/1`).
- Booster-on-unmatched-row → existing warning preserved (`import_live.ex:141`).
- Per the LiveView discipline rule: validation stays at the boundary (`rows_from_envelope/2`
  returns tagged results); the LiveView pipes validated data, no `try`/`raise`.

## Testing

- **`rows_from_envelope/2` (unit):** real envelope shape → correct rows with injected round;
  bare-array input; empty `predictions`; missing/garbage keys → `{:error, :bad_envelope}`;
  knockout-shaped fields ignored for group rounds.
- **`ImportLive` (LiveView, full flow):**
  - mobile UA → renders the copy-paste flow, Round 1 only; pasting valid Round 1 → inline
    preview → confirm **writes Round 1** via the real `Predictions.admin_save_round_predictions/3`
    and reveals Round 2; repeat to Round 3 → final success state.
  - **tab-discard / remount persistence (the regression this design exists to prevent):** after
    confirming Round 1, simulate a fresh `mount` (new `live/2` session = the discarded-tab
    reload). Assert Round 1's predictions are still in the DB (durable, not in assigns) — i.e.
    progress is not lost. This is the test that the naive accumulate-then-confirm design would
    fail.
  - desktop UA → renders the relabelled bookmarklet steps; no console-fallback copy present;
    single confirm writes all pasted rounds.
  - jargon assertion: rendered HTML for both UAs contains none of "bookmarklet"/"JSON"/
    "console" (case-insensitive).
  - bad paste → inline error, the current round is recoverable (re-paste), already-saved rounds
    untouched.
- Tests use production write paths (no hand-set fixtures), per project rules.

## Scope boundaries (YAGNI)

**In:** platform-aware copy + flows, mobile progressive copy-paste, raw-envelope paste,
jargon purge, escape-hatch copy, confirmation state, group stage (rounds 1–3).

**Out (file as follow-ups, do not build here):**
- iOS Shortcut ("Run JavaScript on Web Page") as a smoother iPhone path — promising but
  **untested** and the developer has no iPhone; needs an iPhone-owning group member to validate
  the full cold-start (enable-scripts toggle + per-domain prompt) before committing.
- Vision/OCR parsing of screenshots to remove admin toil on the escape-hatch path.
- Knockout import (`i9k`).
- Real illustrative screenshots/gifs: the spec leaves `[screenshot: …]` slots; the operator
  captures them from a live FIFA session (cannot be done from code).

## Pre-build validation (cheap, do first)

The spike confirmed the JSON *loads* on Android; it did **not** confirm a non-technical user can
*extract* it. Before building, do the gesture live on the Android phone: open
`…/prediction/show/1`, long-press the page → **Select All → Copy** → paste into any text field.
Confirm (a) Chrome offers "Select All" on a raw-text page and (b) the whole 24-prediction blob
copies cleanly. If that gesture is awkward even for a developer, the copy-paste path's mum-test
verdict is effectively already "no", the escape hatch carries more load than assumed, and we
should reconsider weighting before investing in the illustrated mobile flow.

## Risks

- **Akamai/endpoint drift:** FIFA changes the anti-bot scheme or `show/{round}` shape
  mid-tournament. Mitigation: the screenshot→admin escape hatch and admin entry (`a02`) remain
  the guaranteed path; import is a bonus.
- **Mobile select-all-copy is still fiddly** for the genuinely non-technical — mitigated by
  per-round progressive reveal + screenshots + the escape hatch, but the literal-mum case is
  expected to use the escape hatch, and that is acceptable.
- **iOS top-level nav unverified:** assumed to behave like Android (works), but no iPhone to
  confirm. If it fails on iOS, iPhone users fall back to the escape hatch until the Shortcut
  follow-up lands.
