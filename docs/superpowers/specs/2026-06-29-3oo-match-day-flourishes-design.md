# Match-day flourishes — celebratory toasts on results sync — design

- **Bead:** `predictex-3oo`
- **Date:** 2026-06-29
- **Status:** design (awaiting user review → `writing-plans`)
- **Builds on:** the PubSub live-update architecture (ADR 0002) — this adds a **fourth topic
  granularity**, `player:<id>`, for targeted per-player events; `Scoring.Standings` (ranked board),
  `MatchRecap.points/2` (per-pick scoring), and the settle write edges `Results.Ingest.commit/1` +
  `Results.FifaFallback`.
- **Related:** `predictex-x16` (live presence — the prior "feels live → live people" step; this is
  "live → live *celebration*"). The `.animate-pdx-rise/-pop/-glow` keyframes and `.font-score`
  shipped in `app.css` (design section 07, footer ②); a static `-rise` is already on the champion hero.

## Problem

Design section 07 + footer item ② call for celebratory toasts on match-day events. The CSS
(keyframes + `.font-score`) already ships; the **triggering** is unbuilt. When a fixture settles on
the 15-minute `ResultSync`, three things worth celebrating can happen to a player and currently pass
silently:

1. **rank-climb** — the player moved up the leaderboard.
2. **exact-score** — the player's pick exactly matched the final scoreline.
3. **booster-hit** — the player's 2× booster pick scored points.

There is no per-player delivery channel today: ADR 0002's topics are fixture-scoped
(`fixture:<id>`), coarse (`fixtures:changed`), and the FIFA fan-out (`fifa:snapshots`) — none target
one player. This feature adds that channel and the detection behind it.

## Decisions taken (brainstorm 2026-06-29)

- **All three events** in v1 (not a climb-only slice).
- **Persist + replay**, not fire-and-forget: a flourish missed because the player had no page open
  is shown on their next visit. This makes it a lightweight per-player notification, with a small
  schema and `seen_at` bookkeeping — accepted deliberately over the ephemeral option.
- **Visual: A/C blend** — a "stadium scoreboard" toast (dark card, glowing `font-score` numerals,
  uppercase pill label, emoji), with the hero **rank-climb** toast *popping* in + glow-pulsing while
  exact/booster gently *rise*.
- **Delivery mechanism A** — server `push_event` → client JS hook builds/animates/auto-dismisses the
  toast. The server holds **no display state**; the DB is only for persistence/replay/seen.

## 1. Data model — `Flourishes` context + `Flourishes.Flourish` schema

New context `Predictex.Flourishes` (public API), co-located schema `Flourishes.Flourish`, new
migration. Per the domain-layer conventions, the schema lives under the context namespace.

```
flourishes
  id
  player_id   FK → players  (on_delete: :delete_all)
  kind        Ecto.Enum [:rank_climb, :exact_score, :booster_hit]
  fixture_id  FK → fixtures, nullable   -- set for exact/booster; null for rank_climb
  from_rank   :integer, nullable        -- rank_climb only
  to_rank     :integer, nullable        -- rank_climb only
  points      :integer, nullable        -- exact/booster: points gained
  detail      :string,  nullable        -- denormalised label, e.g. "Brazil 2–1 Japan"
  seen_at     :utc_datetime, nullable
  inserted_at :utc_datetime             -- (timestamps, updated_at omitted — rows are immutable bar seen_at)

indexes:
  (player_id, seen_at)                                       -- "unseen for player" query
  UNIQUE (player_id, kind, fixture_id) WHERE fixture_id IS NOT NULL  -- partial; dedup
```

`detail` is **denormalised at detection time** so replay needs no fixture join and survives later
fixture mutation (KO team resolution, re-sync). The partial unique index makes detection **idempotent**:
a player gets at most one exact/booster flourish per fixture; re-records use `on_conflict: :nothing`.
`rank_climb` rows (null `fixture_id`) are not constrained — see §3 for why re-runs don't duplicate them.

Public API:
- `record(attrs_list)` — bulk insert with `on_conflict: :nothing`.
- `unseen_for(player_id)` — list, oldest first.
- `mark_seen(ids)` — idempotent `UPDATE … WHERE id IN ? AND seen_at IS NULL`.
- `detect(before_board, after_board, scored_settled)` — **pure**, returns attrs maps (see §2).
- `from_settle(before, after, newly_settled)` — imperative orchestrator: scores picks, calls
  `detect`, `record`s, broadcasts (see §3).
- `toast(flourish)` — **pure** render map `%{kind, emoji, pill, label, value}` for the client (§5).

## 2. Detection — pure core `Flourishes.detect/3`

A thin mapper over already-computed inputs, so the scoring and ranking **laws stay in their existing
cores** (`Scoring.Engine`, `Scoring.Standings`); `detect` invents no new scoring.

Inputs:
- `before_board`, `after_board` — ranked leaderboards (`[%{player_id, rank}]`) from
  `Standings.leaderboard()` before/after the settle.
- `scored_settled` — `[%{fixture_id, detail, picks: [%{player_id, exact?, booster?, points}]}]` for
  fixtures that **newly** settled this run (built by the shell from `MatchRecap.points/2`).

Output — a flat list of flourish attrs maps:
- **rank-climb**: for each player present in *both* boards with `after.rank < before.rank` →
  `%{kind: :rank_climb, player_id, from_rank, to_rank}`. A player **not in `before_board`** (newly
  entering the ranking) is **skipped** — no "climbed from nowhere" spam on the first settle.
- **exact**: per settled fixture, per pick with `exact?` → `%{kind: :exact_score, player_id,
  fixture_id, points, detail}`.
- **booster**: per pick with `booster? and points > 0` → `%{kind: :booster_hit, player_id,
  fixture_id, points}`.

`exact?` is a direct scoreline equality (`pick.home == final.home and pick.away == final.away`) —
unambiguous regardless of engine tiers. A pick can yield **both** an exact and a booster flourish
(boosted *and* exact) — two distinct toasts, intentionally.

## 3. Settle-edge wiring — imperative shell

Both settle producers bracket their existing write. In `Results.Ingest.commit/1` (and the equivalent
point in `Results.FifaFallback`):

1. `before = Standings.leaderboard()` — **before** the upserts.
2. upserts (existing) — `upsert_fixture/2` returns whether the row **transitioned** open→completed
   this run, so the shell can collect `newly_settled` (a status-transition set, not "every settled
   fixture" — that is what keeps re-syncs from re-detecting).
3. `after = Standings.leaderboard()`.
4. `Flourishes.from_settle(before, after, newly_settled)` — scores each newly-settled fixture's picks
   via `MatchRecap.points/2`, builds `scored_settled`, calls `detect`, `record`s, and broadcasts each
   **persisted** flourish (the row, with its `id`) to `player:<player_id>` (§4). Only newly-inserted
   rows are broadcast: a `on_conflict: :nothing` dedup returns no row, so an already-recorded flourish
   is silently not re-sent.

**Best-effort, never blocks a settle.** `from_settle` is wrapped in `rescue`+`Logger` exactly like the
ADR-0002 capture subscribers — the settle has already committed and `Tournament.broadcast_change()`
has fired; a flourish failure logs and is swallowed. Flourishes are a flourish, not a settle invariant.

**Idempotency of `rank_climb`** (the un-constrained rows): a re-run that settles nothing produces
`before == after` (no DB change between the two reads) → no climb detected. A re-run that settles a
*new* fixture computes a *fresh* before/after for that run only. So climbs are scoped to the run that
actually moved the board; there is no accumulation across idempotent re-syncs.

Out of scope for triggering: `mix predictex.preview_knockout`, the `Replay` engine, and live-score
ticks (`LiveScore.apply_to_fixture`) — flourishes fire **only** at the two result-settle edges.

## 4. Delivery — `player:<id>` topic + one `on_mount` hook

New PubSub topic granularity `player:<id>` (ADR 0002's **Topic 4** — fine-grained, one *player*).
A single `on_mount` hook, `PredictexWeb.FlourishToasts`, added to the **authenticated** `live_session`
in `router.ex` (`:require_authenticated_player`); flourishes are per-logged-in-player, so public pages
are excluded. Using `Phoenix.LiveView.attach_hook`, the one module covers **every authenticated page**
with no per-LiveView edits:

- **on connected mount** (`connected?(socket)` guard): `subscribe "player:<id>"`; load
  `unseen_for(id)` → `push_event "flourish"` for each → `mark_seen`.
- **`attach_hook(:handle_info)`**: on `{:flourish, flourish}` → `push_event "flourish"` (carrying the
  `id` and the `toast/1` render map) + `mark_seen([flourish.id])`.

`mark_seen` on both paths is idempotent (`WHERE seen_at IS NULL`), so multi-tab and live-then-revisit
never double-replay. The **display** of a toast is independent of the DB mark — the toast always shows;
the mark only suppresses future *replay*. One narrow race remains — a broadcast arriving between the
mount's `unseen_for` read and its `mark_seen` write could push the same flourish twice — so the client
hook **dedupes by flourish `id`** (tracks shown ids), making a double-push a no-op cosmetically.

## 5. Render — client JS hook `FlourishToast`

A container in `Layouts.app` (the shared authenticated layout):
`<div id="flourish-toasts" phx-hook=".FlourishToast" class="toast toast-top toast-end z-50">`.
A colocated hook (`Phoenix.LiveView.ColocatedHook`, the pattern already used by `leaderboard_live`'s
`CopyWhatsApp`) handles `flourish` events:

- builds the **A/C-blend** scoreboard toast from the event payload (`Flourishes.toast/1` shape):
  dark card, `font-score` glowing numeral for `value`, uppercase `pill`, `emoji`, per-kind colour
  (climb → amber/`warning`, exact → `success`, booster → `accent`).
- **motion**: `rank_climb` gets `animate-pdx-pop` + a glow pulse; exact/booster get `animate-pdx-rise`.
- **stacks** multiple, **auto-dismisses** after ~6s (CSS fade then remove), **click-to-dismiss**.

No server display state; the hook owns the transient DOM. Copy (per `toast/1`):

| kind | emoji | pill | label | value |
|---|---|---|---|---|
| rank_climb | 📈 | RANK UP | `Now #{to_rank}` | `▲#{from_rank - to_rank}` |
| exact_score | 🎯 | EXACT | `detail` (e.g. "Brazil 2–1 Japan") | `+#{points}` |
| booster_hit | ⚡ | BOOSTER | `2× landed` | `+#{points}` |

## 6. Testing

- **`detect/3` (pure)** — unit: climb when rank improves; no climb when equal/worse; new-player
  skipped; exact on scoreline match (and not on near-miss); booster only when boosted **and** points
  > 0; boosted-exact yields both.
- **Context** — `record` inserts; `unseen_for`/`mark_seen` round-trip; `on_conflict: :nothing` dedup
  via the partial unique index (second record of same player/kind/fixture is a no-op).
- **Settle integration** — drive `Results.Ingest.commit/1` with a fixture where a player nails the
  score **and** climbs; subscribe to `player:<id>`, assert rows created **and**
  `assert_receive {:flourish, %{kind: :exact_score}}` (+ `:rank_climb`). Assert `from_settle` failure
  is swallowed (settle still succeeds) by forcing an error path.
- **LiveView** — mount-replay: an unseen row is delivered via `assert_push_event "flourish"` on
  connected mount and then marked seen (a second mount delivers nothing); live delivery: a broadcast
  while mounted pushes the event. Test on one authenticated LiveView (the hook is shared).
- **JS hook** — verified manually (no JS test harness in the repo); kept minimal.

## 7. ADR amendment

Amend `docs/adr/0002-pubsub-live-update-architecture.md` with **Topic 4 — `player:<id>`**: the
targeted, per-player granularity for match-day flourishes, recorded after the settle write (same
broadcast-after-write rule), best-effort. Completes the topic-granularity story: fan-out → per-match →
coarse-aggregate → **per-player**.

## Scope note

Larger than `x16`: migration + schema + context (pure `detect` + `toast`, effectful `record`/query/
`from_settle`) + settle-edge wiring in two producers + `on_mount` hook + layout container + colocated
JS hook + ADR amendment. One coherent vertical, suitable for a single implementation plan. No feature
is deferred; the only explicit non-goals are the three out-of-scope trigger sources in §3.
