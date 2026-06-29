# ADR 0002 — PubSub architecture: how the app feels "Live"

- **Status:** Accepted (documents the as-built design)
- **Date:** 2026-06-29
- **Deciders:** davewil
- **Related:** `predictex-rfm` (live buzz: capture → decode → broadcast), `predictex-9p0`
  (PubSub replaces the dashboard poll), `predictex-i1s` (replay engine over the captured
  event source), [ADR 0001](0001-capture-worker-deployment-isolation.md) (the single-node
  assumption this design rests on, and what a worker-split would cost it).

## Context

The product promise is that scores, standings, brackets and the "what-if" buzz update
**by themselves** while a match is on — no refresh button. That liveness is delivered
entirely by one `Phoenix.PubSub` instance (`Predictex.PubSub`, started in
`application.ex` before the Endpoint). There is no polling on the hot path: a clock
`:tick` timer in `MyPredictionsLive` only advances the *displayed* minute; the data
arrives over PubSub (`predictex-9p0` removed the old dashboard poll).

This ADR records *why the topic design is shaped the way it is*, because the shape — not
the fact that we use PubSub — is what makes it correct and cheap. The ingestion producer
is an Oban cron worker (`Workers.LiveScoreSync`) polling the FIFA `/detail` endpoint
during a fixture's live window; everything downstream is PubSub.

## Decision drivers

- **No refresh button.** A score change must reach every relevant open view within
  seconds, without the client asking.
- **Persistence and interpretation must not be coupled.** We want a lossless, replayable
  record of raw FIFA frames *and* a live decode, without one depending on the other
  (`predictex-rfm`, `predictex-i1s`).
- **Effects at the edges.** Consistent with the app's pure-core / imperative-shell model:
  broadcasts are side-effects fired from the write edge, never from a pure core.
- **Proportionate to a ~15-person homelab league.** No clustering, no extra infra. A
  single-node in-memory PubSub is enough — and ADR 0001 records what it would take to
  relax that.

## Decision — three topics at three granularities, plus broadcast-after-write

All liveness flows through `Predictex.PubSub` over **three deliberately distinct topics**.
The granularity split is the core decision.

### Topic 1 — `"fifa:snapshots"` (ingestion fan-out)

`Workers.LiveScoreSync` fetches a FIFA `/detail` body and publishes it raw:

```elixir
Phoenix.PubSub.broadcast(Predictex.PubSub, "fifa:snapshots",
  {:snapshot, fixture_id, body, captured_at, fifa_match_id, url})
```

**Two independent GenServer subscribers** (both started in `application.ex`'s
`capture_subscribers/0`, gated by `:start_capture_subscribers`) each receive every frame:

| Subscriber | Responsibility |
|---|---|
| `Capture.Recorder` | Persists the raw frame to `fifa_captures` — the replayable event source |
| `LiveScore.Updater` | Decodes the body → `LiveScore.apply_to_fixture/2` → writes `live_*` columns |

These are **siblings, not a pipeline**: the Recorder does not know the Updater exists.
That decoupling is what lets the `Replay` engine (`predictex-i1s`) re-decode captured
frames later without re-fetching from FIFA, and lets either subscriber crash (each
`rescue`s and logs in `handle_info`) without taking the other down.

### Topic 2 — `"fixture:#{id}"` (fine-grained, one match)

When `LiveScore.apply_to_fixture/2` commits a change to a fixture's `live_*` values, it
broadcasts a targeted tick:

```elixir
Phoenix.PubSub.broadcast(Predictex.PubSub, "fixture:#{fixture.id}", {:live_update, fixture.id})
```

`FixtureLive` (the per-match drill-down) subscribes to *its own* fixture topic on mount
and re-pulls its full projection on `{:live_update, _id}`. Only viewers of that match are
woken.

### Topic 3 — `"fixtures:changed"` (coarse, "something changed — re-pull")

`Tournament.subscribe_changes/0` / `broadcast_change/0` wrap a single topic carrying one
payload-free message, `:fixtures_changed`. It is broadcast **after every DB write that
could move an aggregate view**, from several producers:

- `LiveScore.apply_to_fixture` (live scores)
- `Results.Ingest.commit` and `Results.FifaFallback` (settles + final results)
- `Fifa.KnockoutTeams` (resolved knockout teams)
- `Predictions` writes (`broadcast_on_success`, only on `{:ok, _}`)
- the `mix predictex.preview_knockout` task

The aggregate LiveViews — `MyPredictionsLive` and `BracketLive` — subscribe once and
re-pull on `:fixtures_changed`. `LiveScore.apply_to_fixture` is the only producer that
fires **both** topic 2 (precise, for the open match) and topic 3 (coarse, for the
dashboards) — one write edge serving both audiences.

### Cross-cutting rules

- **Broadcast AFTER the DB write, never before.** The producer commits, then rings the
  bell; subscribers always read committed state. This is what stops a read-model view
  rendering a value that isn't durably persisted yet.
- **Coarse-by-design.** `"fixtures:changed"` carries no diff — it's a doorbell, not a
  payload. Over-broadcasting just costs subscribers a cheap re-pull; *missing* a broadcast
  leaves a stale board, so producers err toward firing too often (see `predictions.ex`).
- **Subscriptions guarded by `connected?(socket)`** so they run only on the live WebSocket
  mount, not the initial dead render.

### Separate layer — forced disconnect

`player_auth.ex` uses `PredictexWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})`
on logout / session revocation. This is Phoenix's socket-level mechanism (keyed by
`live_socket_id`), not one of the three domain topics — a different layer over the same
PubSub, used to force a user's LiveView sockets to drop and re-authenticate.

## Why not the alternatives

- **Polling the DB from each LiveView** — what `predictex-9p0` removed. Simpler, but adds
  per-client DB load proportional to viewers × poll-rate and a visible latency floor; the
  push model is both cheaper and snappier at this scale.
- **One topic for everything** — would force the per-match drill-down to wake on every
  unrelated fixture change, and the dashboards to parse a payload they'd re-pull anyway.
  Splitting coarse (`fixtures:changed`) from fine (`fixture:#{id}`) is what keeps each
  consumer's wake-ups relevant.
- **A single fat broadcast carrying the changed data** — rejected in favour of the
  payload-free doorbell + re-pull: the re-pull reads committed state through the existing
  query path (one source of truth), avoiding a second, drift-prone serialization of the
  same data over the wire.

## Consequences

- **Positive:** the app feels live with no client polling; persistence and live decode are
  independently evolvable and independently replayable; broadcasts stay at write edges,
  consistent with the pure-core model; the whole mechanism is ~three topics and a handful
  of `broadcast`/`subscribe` calls.
- **Negative / cost:** "broadcast after every write" is a discipline a new write path must
  remember — a missed `broadcast_change/0` is a silent staleness bug, not a crash. The
  coarse topic trades precision for safety (extra re-pulls under churn).
- **Load-bearing assumption — single node.** All of this assumes producer and subscribers
  share one BEAM node, so in-memory PubSub delivery just works. **This is the constraint
  ADR 0001 is about:** splitting the capture worker into its own container would put the
  `"fifa:snapshots"` / `"fixtures:changed"` producers on a different node from the
  subscribed LiveViews, and the broadcasts would not cross without a Postgres-backed
  PubSub (LISTEN/NOTIFY). Any move off single-node must carry that change or liveness
  silently stops.

## Trigger to revisit

Revisit if/when ADR 0001's worker-split is implemented (the single-node assumption breaks
and topics 1 & 3 must cross the process boundary via Postgres-backed PubSub), or if the
coarse `"fixtures:changed"` re-pull volume becomes a measured cost rather than a
negligible one.
