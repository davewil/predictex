# ADR 0001 — Isolating the live-capture worker from web deploys

- **Status:** Deferred (curiosity-driven design exploration; not scheduled)
- **Date:** 2026-06-23
- **Deciders:** davewil
- **Related:** `predictex-4ya` (persist event source in the capture producer — lossless
  recording), the "never `git tag` mid-capture" deploy rule (RESUME.md, CLAUDE.md),
  `predictex-9p0` (the single-node PubSub the live dashboard currently relies on).

## Context

A deploy is `docker compose -f docker-compose.prod.yml … up` which **recreates the app
container**. The live-capture producer — `Workers.LiveScoreSync`, an Oban cron job
(`*/5`) — runs *in-process* inside that container, along with the PubSub subscribers
(`Capture.Recorder`, `Live.Updater`) that persist frames and push `{:live_update}` to
LiveViews. Recreating the container mid-match kills the in-flight job; the frames it has
fetched but not yet persisted are lost. The `*/5` cron re-arms within ~5 min, so the
*match* isn't lost, but a window of buzz frames is.

Today we manage this with a **process rule**: don't tag a release while a match is live
or capturing (plain `main` pushes are always safe — Quality job only, no recreate). The
rule is cheap and adequate — matches are scheduled, short, and we control deploy timing
— but it means a web change can be *blocked for hours* by an in-progress game.

The question this ADR records: **if we wanted to remove that constraint rather than
schedule around it, what would we do, and why not multi-node?**

## Decision drivers

- Web changes are frequent; capture-worker changes are (eventually) rare. We want the
  frequent event to never collide with a live match.
- The fix should be proportionate to a ~15-person homelab league — minimal new
  operational surface, no infrastructure we have to babysit.
- It should stay consistent with the app's "pure cores, effects at edges / two-writer
  rule" architecture rather than fighting it.

## Options considered

### 1. Status quo — schedule deploys around matches (current)
Cheap, zero infrastructure. Cost: a web fix can wait hours for a match window to close.
**This remains the default until a driver below actually bites.**

### 2. Multi-node web tier (rolling deploy)
Run `n` app containers behind caddy; recreate them one at a time for zero-downtime
*serving*.

**Rejected as a fix for this problem.** It solves request-serving downtime, not capture
frame-loss. Oban's Postgres-backed uniqueness already makes the `*/5` job singleton
across a cluster, so only one node captures — but a rolling deploy still recreates
*that* node eventually, and its in-flight frames live only in its memory. More replicas
shrink the gap, they don't close it. Worse, it reintroduces BEAM clustering (libcluster
+ a distributed PubSub adapter) so `"fifa:snapshots"` / `"fixtures:changed"` broadcasts
cross nodes — significant cost for no benefit to the actual failure mode.

> **Insight:** frame-loss is a *capture-durability* problem, not a *node-count* problem.
> Node count protects stateless request serving; capture is stateful in-flight work, and
> stateful work is made restart-safe by durability or graceful drain, not by replicas —
> the state isn't replicated, it's ephemeral on whichever node holds it.

### 3. Capture worker as its own deployable — **one image, two roles** (chosen direction)
Not a second codebase or image. The same release image, started as two container roles
with different Oban config:

- **web role** (`n` containers): capture cron/queue **disabled** — pure serving,
  recreate freely on every web deploy.
- **worker role** (1 container): cron enabled — runs `LiveScoreSync`, `KnockoutIds`,
  `ResultSync`, `CohortSync` — recreated only when *we* choose.

A web deploy never touches the worker, so it's safe mid-match. A worker deploy is the
rare event we still schedule around (and `4ya` below makes even that safe).

**The real cost — the process boundary splits, and the live dashboard's PubSub
(`predictex-9p0`) currently assumes a single node.** The worker broadcasts on
`"fixtures:changed"` / `"fifa:snapshots"`; the LiveViews subscribed to them live in the
*web* containers. Two unclustered BEAM nodes → those broadcasts never cross → live buzz
silently stops reaching users. The proportionate answer routes the signal through the
store we already share:

> Use a **Postgres-backed PubSub** (LISTEN/NOTIFY) instead of the in-cluster PG2 adapter.
> The worker's broadcast reaches the web nodes *through the database* — no libcluster, no
> second clustering dependency. This keeps "effects flow through the durable shared edge,"
> consistent with the rest of the app. Without it, you'd fall back to reinstating a short
> dashboard poll as the cross-node transport (the thing `9p0` removed).

### 4. Capture durability — `predictex-4ya` (complementary, not exclusive)
Persist each fetched frame to `fifa_captures` the instant it arrives (event-sourced),
rather than buffering it in the job. A mid-capture recreate then resumes from the last
persisted frame instead of losing the buffer. **This is the only option that fixes
*unplanned* worker restarts** (host reboot, OOM, crash) — which option 3 does nothing
for. Needs no new infrastructure.

## Decision

**Defer all of it.** The current process rule (option 1) is the right default at this
scale. When we choose to remove the constraint, the direction is **option 3 (worker-role
split + Postgres-backed PubSub), with option 4 (`4ya`) as cheap insurance for unplanned
restarts** — explicitly **not** multi-node.

This is deferred, not rejected, because the premise of option 3 ("the worker contract is
stable") **is not yet true**: `ius` just changed `LiveScoreSync`, and `Workers.KnockoutIds`
is brand-new and unverified until the 28 Jun knockout cutover. Splitting a still-churning
worker would just move the deploy friction, not remove it.

## Requirements for the deferred option (so they aren't lost)

If/when we implement option 3:

1. **Per-role Oban config** — drive `queues:` / `crontab:` from runtime config so the
   same image runs cron on the worker role and not on web roles. (One env var, e.g.
   `CAPTURE_ROLE=web|worker`, gating the cron/queue keys in `application.ex` / config.)
2. **Postgres-backed PubSub** — replace the in-cluster adapter so `Tournament`'s
   `"fixtures:changed"` and the `"fifa:snapshots"` topic cross the web/worker process
   boundary via Postgres LISTEN/NOTIFY. Verify the live dashboard (`9p0`) and live buzz
   still update with the producer in a *separate* node. This is the one substantive
   change; everything else is config.
3. **Deploy orchestration** — `ci-deploy.yml` recreates the web role on every `v*` tag;
   the worker role is recreated on a separate, explicit trigger (or the same tag but
   gated on "no match live right now"). Keep the "don't recreate the worker mid-capture"
   rule until `4ya` lands.
4. **`4ya` first, ideally** — landing capture durability before the split means even the
   rare worker deploy (and any crash/reboot) is frame-safe, removing the last scheduling
   constraint entirely.
5. **Single-host caveat** — on the homelab's single Docker host, "two roles" is two
   containers on one machine: no HA, just deploy isolation. That's the intended scope;
   don't let it grow into a real cluster without a driver that justifies it.

## Consequences

- **Positive:** web deploys become safe at any time, including mid-match; the change is
  mostly config, not new architecture; no libcluster; stays within the existing
  effects-at-edges model.
- **Negative / cost:** a Postgres-backed PubSub migration that must be verified end-to-end
  for the live dashboard and buzz; a second container role to operate and observe; the
  worker deploy path still needs care until `4ya`.
- **Neutral:** none of this is needed while option 1 holds. Revisit when a web fix is
  *actually* blocked by a match window often enough to hurt — and only after the capture
  worker contract has stopped moving (post-28-Jun, KO machinery proven).

## Trigger to revisit

Reopen this ADR when **both** hold: (a) the `hco`/KO capture machinery has been verified
through the 28 Jun cutover and the worker contract is stable, **and** (b) deploy-blocked-
by-match has become a recurring friction rather than an occasional wait.
