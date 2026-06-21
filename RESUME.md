# RESUME — predictex

Fast-orientation handoff. Read this first when starting a new session.

## What this is
**predictex** — a FIFA World Cup 2026 score-predictor game for a private ~15-person
WhatsApp league. Phoenix LiveView app deployed on a homelab. Members predict scorelines;
the app scores them against real results and ranks a leaderboard.

> Not to be confused with **uPredict** (`~/dev/uPredict`, an older .NET prediction app).
> predictex is a ground-up Elixir build for WC 2026 — spiritual successor, not a port; no shared code.

## Live right now
- **URL:** https://wc-predict.davewil.dev  (deployed, valid TLS)
- **Latest deployed tag:** `v0.11.10` (deployed + verified 2026-06-20: Deploy success, migration
  `AddSourceNumToFixtures` applied in prod, `/health` 200, anon `/` 200) — bundles **`9p0`** (closed:
  `/predictions` live updates via the coarse `Tournament` `"fixtures:changed"` PubSub topic, 30s poll
  removed) **+ `g8m`** (KO fixtures now key on openfootball's stable `num` so a knockout's teams resolve
  in place instead of spawning a duplicate — unblocks `hco` WS1; the 15-min ResultSync bootstraps
  `source_num` onto the 32 KO placeholder rows; full no-dup verification at bracket resolution).
- **Prior deployed tag:** `v0.11.9` (deployed + verified 2026-06-20: Deploy job success, `/health` 200,
  anon `/` 200) — **dashboard live tick** (`doz`, closed): `/predictions` self-paced `:tick` re-pulls
  `Dashboard.for_player` over the websocket (no refresh); pure `Dashboard.next_tick_delay/2` (30s live /
  exact gap to next preview-open or kickoff-lock / nil once settled); `Predictions.cta_lead_seconds/0`
  DRYs the 30-min constant. No migration (additive LiveView). Recent: **v0.11.8** match recap **slice 2**
  (`p4o`): settled group-stage `/fixtures/:id` **goal breakdown** (scorer + pen/OG/regular + side),
  FIFA-capture goals when they reconcile with the final score else the persisted openfootball `goals`
  embed (first p4o migration) + a sobelow fix (trusted `File.read!` now an inline `# sobelow_skip`,
  line-stable, vs a drift-prone `.sobelow-skips` fingerprint); **v0.11.7** match recap **slice 1**
  (per-pick points); **v0.11.0** auto-start unified live capture (`rfm`);
  **v0.11.1** server-side per-viewer kickoff times (`fb5`) + live-game CTA on `/predictions` (`afm`);
  **v0.11.2** knockout ET/pens capture window + `is_live` auto-clear sweep (`cvx`/`d17`);
  **v0.11.3** `/predictions` live CTA opens 30 min pre-kickoff → live → post-match recap (`4zu`);
  **v0.11.4** next-match countdown banner on `/predictions` (`vg7`, ungated — low-impact);
  **v0.11.5** contracted the `:live_buzz` flag (`uhf`);
  **v0.11.6** public leaderboard highlights the logged-in player's own row (`kzz`) + shared
  `AdminWriteResult` helper across admin LiveViews (`r90`, no user-visible change).
  **Live buzz is now UNCONDITIONAL** — the `:live_buzz` flag was contracted away (`uhf`, deployed
  v0.11.5): the parallel change is complete (accepted in prod → flag + gates + off-tests removed).
  No user-visible change (the flag was already ON). ⚠️ **No kill-switch any more** — if the FIFA
  live feed misbehaves, the lever is revert+redeploy, not a flag flip. FunWithFlags dep +
  `/admin/feature-flags` dashboard are retained as the dark-ship mechanism for future flags.
- **League invite code:** `wcpredict2026`
- **Prod state:** 12 fixtures synced. **Admin console (`/admin`) + My Predictions
  (`/predictions`) live; results + cohort now auto-sync (Oban).** Admins can enter predictions
  on behalf of players (game is playable). **`mt6`** = ResultSync worker (every 15 min, openfootball);
  **`7ux`** = CohortSync worker (hourly, FIFA `matchStats.json` → `cohort_*_pct`, drives the risky
  bonus — no more manual cohort entry). Both on Oban (added in v0.5.0; `oban_jobs` migration).
  Members still show "no pick imported" until an admin transcribes their FIFA screenshots.
- **Prediction-entry model (important):** predictions are **never entered in-app by members**.
  Members make them on the official FIFA Match Predictor; they reach predictex via **admin
  entry on behalf of players** from screenshots (`a02`, **shipped** — `/admin/predictions`)
  or **member self-import** (`xox`, **code-complete & reviewed, pending manual validation** —
  `/import`). `/predictions` only *displays* them.

## ⏵ Continue here (2026-06-21)

**Latest deployed tag `v0.11.12`** (deployed + verified 2026-06-21: Deploy success, `/health` 200, anon
`/` 200) — bundles **`kcx`** ("If your pick lands" projected leaderboard on `/fixtures/:id`: per-viewer
what-if on the member's OWN scoreline pick; pre-kickoff shows only the viewer's own row/headline, full
board after kickoff — anti-copy render gate; v1 scoreline-only w/ knockout caveat; unconditional, read-only)
**+ `i1s` adaptive replay pacing** (`Replay.tick_delay_ms/1`: 1400ms dwell on score-change frames, 250ms
rush through minute-only filler — was a flat 1s/frame that crawled). No migration (both additive).
Reviewed clean (kcx: code-reviewer, no material issues). Spec/plan:
`docs/superpowers/{specs/2026-06-21-kcx-pick-projection-design.md,plans/2026-06-21-kcx-pick-projection.md}`.
**Eyeball-then-close:** `kcx` (pre-kickoff fixture w/ a pick → only your row "you'd be #N ▲Δ", no other
names; after kickoff → full board) and `i1s` (one real replay at the new pace: `400021510` / `400021504`).

**Prior deployed tag `v0.11.11`** (deployed + verified 2026-06-20) — bundles **`hco` WS4** (knockout first-team/first-scorer in the `/fixtures/:id` picks reveal)
**+ `i1s` match replay**: replay a completed fixture's captured buzz timeline as a read-only, in-process,
time-compressed playback driving the existing `/fixtures/:id` UI — no DB writes, no fabricated demo
fixture (the 2026-06-17 demo-fixture spec was superseded). Pure `Replay.frames/1` + shared immutable ETS
`Replay.Cache` + `FixtureLive` replay mode (`@view_fixture` shadow, recap-off, buzz-recompute-on-score-change,
stay-on-final-frame). `cil` (admin toggle) folded in + closed.
Spec/plan: `docs/superpowers/{specs/2026-06-20-match-replay-strategy-design.md,plans/2026-06-20-match-replay.md}`.

> ✅ **`:match_replay` flag is now ON in prod** (enabled 2026-06-21 via `rpc FunWithFlags.enable`; verified
> `enabled?` → true). Replay is live for all players. **`i1s` bead still OPEN pending a manual eyeball
> smoke-check** of one real replay (Ghana v Panama `400021510` / Uzbekistan v Colombia `400021504`) — the one
> thing CI can't vouch for. Kill switch if the buzz misbehaves: `rpc 'FunWithFlags.disable(:match_replay)'`
> (no redeploy needed — that's the point of the dark-ship flag).

> ⚠️ **FunWithFlags compile-env gotcha (learned the hard way, v0.11.11):** do NOT override
> `:fun_with_flags, :cache` in `config/test.exs` — it's a `compile_env` and CI caches the compiled dep on
> `mix.lock`, so a test-only override fails CI's compile-env validation while passing locally (stale local
> `_build`). Flag tests isolate via an `on_exit` `FunWithFlags.Store.Cache.flush/0` (pure ETS) instead.

> 🚫 **DEPLOY FREEZE from 17:00 (2026-06-21) — Spain match.** No `git tag vX.Y.Z` during the live-match
> window (a container recreate drops in-progress capture frames). v0.11.12 landed ~16:52 BST, before
> kickoff. Plain `main` pushes are fine (Quality job only, no recreate); only tags deploy. Resume deploys
> after the match finishes and capture clears.

**`g8m` post-deploy VERIFIED** (2026-06-21 prod read: all 32 KO fixtures have `source_num` — `{32, 32}`);
final no-dup confirmation still awaits bracket resolution. `hco` WS1 (fifa_match_id backfill) still gated on
bracket resolution. Next session picks from the backlog below.

**Features shipped today (2026-06-20):**
- **`v0.11.10` — `9p0` PubSub dashboard updates (CLOSED) + `g8m` KO fixture identity (open, verify@resolution).**
  - `9p0`: `/predictions` no longer polls every 30s. `Tournament.subscribe_changes/0`+`broadcast_change/0`
    own a coarse `"fixtures:changed"` topic, broadcast post-DB-write by `LiveScore.apply_to_fixture/2` (live)
    and `Ingest.commit/1` (settle); `MyPredictionsLive` re-pulls on it; `next_tick_delay/2` dropped the 30s
    branch. TDD + opus review clean. Deferred polish (on issue): minute-only change still triggers a full re-pull.
  - `g8m`: **the hidden `hco` blocker.** KO fixtures had bracket-placeholder teams (`2A`) and were keyed on
    `external_ref`; when openfootball resolves teams the ref changes → auto-ResultSync would **insert a
    duplicate**. Fix: key KO fixtures on openfootball's stable `num` (`fixtures.source_num` + unique index;
    `Ingest.find_fixture` = num for KO / ref for group + ref-fallback bootstrap; dropped `@replace_on_conflict`,
    two-writer rule preserved because the changeset-update casts only parsed attrs). TDD + opus review (highest
    blast-radius change — core ingest + migration) clean. **Unblocks `hco` WS1.** The 15-min ResultSync stamps
    `source_num` onto the 32 KO placeholders; full no-dup verification comes at bracket resolution.
- **`v0.11.9` — dashboard live tick (`doz`, CLOSED).** `/predictions` self-paced `:tick` re-pulls
  `Dashboard.for_player`; pure `next_tick_delay/2`; `Predictions.cta_lead_seconds/0` DRYs the 30-min
  constant. (Parallel-worktree feature merged onto `main`, then verified + shipped.)
- **`v0.11.8` — `predictex-p4o` Slice 2 goal breakdown.** Subagent-driven (Tasks 3–7); `Openfootball.goal_events/1`
  + persisted `goals` embed (migration) → `Capture.goal_events/1` (FIFA) → `MatchRecap.goals/2`
  (FIFA-if-reconciles, else openfootball) → FixtureLive breakdown, **group-stage settled only**.
  - **Sobelow gotcha fixed (`8642b23`):** `.sobelow-skips` fingerprints are **line-keyed**
    (`Sobelow.Finding.fingerprint` includes `vuln_line_no`), so the accepted `File.read!` skip went stale
    when Slice 2 shifted `Ingest.sync_from_file/1` — failing `scripts/pre-deploy` (and CI). Replaced with an
    inline `# sobelow_skip ["Traversal.FileModule"]` (line-stable); `.sobelow-skips` now empty. See CLAUDE.md.
    **`scripts/pre-deploy` earned its keep** — caught the drift locally before the tag burned a cycle.
  - **`predictex-p4o` left OPEN** — close after eyeballing a real settled group fixture's breakdown in prod.
    Cards remain in `predictex-bdq`.

**▶ NEXT — start here next session:**

1. ~~**`predictex-kcx`** — "if your pick lands" projected leaderboard.~~ ✅ **CLOSED 2026-06-22**
   (built + reviewed + deployed v0.11.12; eyeballed in prod pre-kickoff + live — own row/headline pre-kickoff,
   full board after lock). Shipped surface (for reference):
   `Predictions.get_player_fixture_prediction/2` (anti-copy focused getter) · `Buzz.pick_projection/4` +
   extracted `enrich_rows/2` (shared with `scenarios_with_deltas/3`, one `leaderboard/0` pull, no new math) ·
   `FixtureLive` `@pick_projection` assign + `#pick-projection` render section. Anti-copy resolved via a
   **render gate** (the projected board re-scores every player vs your scoreline, so per-player deltas would
   leak picks pre-kickoff): **pre-kickoff → viewer's own row + headline only** (aggregate rank, no leak);
   **post-kickoff → full top-8 board** (`:if={@picks_visible?}`, picks already public). v1 = scoreline-only
   (knockout undercounts first-scorer bonus → caveat shown; group stage exact). Unconditional, read-only.
   Spec/plan: `docs/superpowers/{specs/2026-06-21-kcx-pick-projection-design.md,plans/2026-06-21-kcx-pick-projection.md}`.
   **Eyeball before close:** a pre-kickoff fixture where you have a pick → card shows only your row + "you'd
   be #N ▲Δ", no other names; after kickoff → full board with your row highlighted. Then `bd close
   predictex-kcx`.

   <details><summary>Original agreed design (2026-06-21) — for reference</summary>

   Add an "If your pick lands" card to `/fixtures/:id` that projects the leaderboard assuming the *viewing
   member's own scoreline pick* for this fixture is the final result. Agreed decisions:
   - **Visibility:** whenever the viewer HAS a pick AND `fixture.status != :completed` (pre-kickoff **and**
     during play; never on a settled fixture — so it never collides with `i1s` replay, which only runs on
     completed fixtures).
   - **Anti-copy:** fetch the viewer's OWN pick directly (a focused `get`, NOT the full picks list — that
     stays hidden pre-kickoff). Own pick only → safe to show before the reveal.
   - **Reuse, no new math:** `Standings.project(fixture_id, your_h, your_a)` + the existing buzz rank-delta
     logic (likely a small `Buzz.pick_projection/3`-style helper returning one scenario's row+delta shape).
     Computed in `load_all` alongside `@scenarios` (same recompute cadence).
   - **Rendering = Approach A:** reuse the "What if…" scenario-card — one card titled "If your pick lands"
     with a headline (e.g. `🇧🇷 Brazil 2–1 → you'd move 7th ▲ 3rd`) + top-8 board, viewer row highlighted.
   - **UNCONDITIONAL** (no feature flag) — low-risk, read-only, reuses tested `project/3`; consistent with
     live buzz being unconditional.
   - **v1 = SCORELINE only.** `project/3` takes only `(h,a)`, so a **knockout** projection would undercount
     the first-scorer bonus uniformly (it can't represent the assumed first-scorer) — DEFERRED refinement
     (would need `project` to optionally take the assumed first-scorer). Group stage (all we have until
     28 Jun) is exact. Note this limitation in the card or spec.
   - **Tests:** pure helper (pick → projected board + delta); LiveView (card shows pre-kickoff with the
     viewer's own pick + correct rank delta; hidden when no pick; hidden when settled; anti-copy: the
     pre-kickoff card exposes only the viewer's own pick, never others').
   </details>

2. **`predictex-i1s` (open) — replay sped up + DEPLOYED (v0.11.12); re-eyeball then close.** Eyeballed
   2026-06-21: worked but too slow. Fixed with adaptive pacing (pure `Replay.tick_delay_ms/1`: 1400ms dwell
   on score-change frames so the buzz is readable, 250ms rush through minute-only filler — was a flat
   1s/frame). Now live in prod. Re-eyeball one real replay at the new pace (Ghana v Panama `400021510` /
   Uzbekistan v Colombia `400021504`) and close. (Tune knobs: the two constants in `lib/predictex/replay.ex`.)

3. ~~**`predictex-p4o`** — eyeball goal breakdown.~~ ✅ **CLOSED 2026-06-21** (eyeballed in prod: settled
   group-stage goal breakdown renders correctly).

4. **`predictex-hco` (P2) — WS1 fifa_match_id backfill, gated on bracket resolution** (after the final group
   match: fetch `rounds.json` + run `Fifa.LiveIds.assign`, confirm 104/104). WS2/WS3 ✅; `g8m` verified
   `{32,32}`; verify WS1/WS2 live on the first KO 28 Jun. (`g8m`'s final no-dup check also lands at resolution.)

5. **Other backlog (`bd ready`):** `4ez` (per-fixture points + risky banner on FixtureCard), `a4j` (cache
   `Standings.leaderboard/0`), `c9s` (team-name snapshot + regression test), `dmh` (ConnCase async-safety),
   `bl8` (Live.Updater rescue), `uyf` (P4, knockout-ET goal filtering — gated on `hco`).

**Workflow rule (this session, durable):** commit autonomously when green; **push and tag/push (deploy) are
the user's explicit call** — never auto-push. Authoritative in CLAUDE.md → "Conventions & Patterns → Commit
/ push / deploy boundary"; bd memory `commit-push-deploy-boundary`.

---

Two threads are healthy and shipped; the **dev-tooling gate is now fully closed** (`unx`/`kvo`/`0cf` all done).

**Live capture + buzz — DONE and live (v0.11.0–v0.11.4).** Auto-start unified capture (`rfm`) is validated
end-to-end on full matches (Ghana v Panama: 167 frames, `is_live` cleared cleanly, two-writer rule held).
Knockout ET/pens window + `is_live` auto-clear sweep shipped (`cvx`/`d17`). `/predictions` shows a live CTA
to `/fixtures/:id` from 30 min pre-kickoff → live → post-match recap (`4zu`) and a next-match countdown
banner (`vg7`). FIFA contract: bd memory `fifa-v3-live-api-contract` (live `MatchStatus` = **3**).

**Dev gate — built this session (principles review → `unx`/`kvo`/`0cf`).** The repo gained
`docs/{engineering-principles,software-delivery-principles}.md` + `docs/ELIXIR_CODE_SMELLS.md`; a review
against them produced a tooling backlog, now mostly shipped:
- **`unx` ✓** — commit-boundary gate: `lefthook.yml` runs `mix precommit` (compile/deps/format/credo/test)
  on every Elixir-staging commit. Beads owns `core.hooksPath`, so the gate is invoked from the committed
  `.beads/hooks/pre-commit` *outside* the beads markers (no separate `lefthook install`). `git commit
  --no-verify` is blocked by a tokenizing Claude Code PreToolUse hook (`scripts/guard-no-verify.py`).
- **`kvo` ✓** — `credo --strict` (tuned `.credo.exs`) in the gate + CI; `sobelow` in CI (baseline in
  `.sobelow-skips`). Verified green in CI.
- **`0cf` ✓** — `scripts/pre-deploy` (mix precommit + sobelow + docker build + a `bin/predictex eval` boot
  smoke test). **Verified end-to-end on Mac/OrbStack (Docker 29.4.0):** ran green through all four steps —
  the `mix assets.setup` Tailwind/esbuild download (which failed under the egress-blocked sandbox) succeeds
  on a networked machine — reaching `== pre-deploy OK — safe to tag ==`. Run it before every `git tag vX.Y.Z`.

**NEXT work + the pending v0.11.10 deploy:** see the **"⏵ Continue here"** block up top — it's the current
source of truth. (`i1s` replay engine is still a live P3 — ⚠️ England v Croatia has **0 captures** (pre-`rfm`),
so guard zero-row match_ids; spec `docs/superpowers/specs/2026-06-17-match-replay-demo-design.md`.)

**DEPLOY mechanics:** `scripts/pre-deploy` → `git tag vX.Y.Z && git push origin vX.Y.Z` (push `main` first).
**Do NOT deploy mid-capture** — the container recreate interrupts the running producer chain (`*/5` cron
re-arms within ~5 min, but you lose frames). Wait for the in-progress match to finish.

**Capture architecture (shipped, `rfm`):** `Predictex.LiveScore` (pure body→`live_*`→broadcast decoder,
also consumed by the replay engine) · `Predictex.Capture` + `Capture.Snapshot` (permanent `fifa_captures`
store; **ops: `Capture.summary("<id>")`**, the old `Spike.summary` is retired) · two supervised PubSub
subscribers on `"fifa:snapshots"` (`Capture.Recorder` persists raw bodies; `Live.Updater`
decode→`live_*`→`{:live_update}`) · `Workers.LiveScoreSync` is the PRODUCER, auto-started by Oban Cron
`*/5` with `unique: [period: 40, states: [:scheduled]]` (the only value that survives the in-job reschedule
AND compiles warning-clean on Oban 2.23). Two-writer rule: FIFA drives `live_*`, openfootball owns
`status`/final score.

## Stack & toolchain
- Elixir **1.20.1** / OTP **28** via **mise** (`.mise.toml`). **Always run `mise exec -- mix …`** — plain `mix` is the wrong version.
- Phoenix **1.8.8**, Ecto/Postgres, `phx.gen.auth` (password), Bcrypt, StreamData.
- Local Postgres: `postgres/postgres` superuser; dev DB `predictex_dev`, test `predictex_test`.
- **408 tests** green (incl. 7 property laws). **The gate is `mix precommit`** (compile --warnings-as-errors,
  deps.unlock --check-unused, format --check-formatted, **credo --strict**, test) — run on every Elixir commit
  by lefthook and by CI's Quality job (CI also runs `sobelow`). Single source = the `precommit` alias in
  mix.exs; tuning in `.credo.exs`/`.sobelow-skips`. Details: CLAUDE.md "Build & Test". Never `--no-verify`.
- **Oban 2.23** (Postgres-backed jobs) added in v0.5.0 — supervised in `application.ex`, cron in `config.exs`, `testing: :manual` in tests. The substrate for `xox` next.

## Architecture (Gather → Decide → Act; pure cores, effects at edges)
- `Predictex.Scoring` — **pure** scoring engine (`score/3`, `round_total/2`). All rulings encoded here.
- `Predictex.Results.Openfootball` — **pure** feed parser (anti-corruption boundary; handles string/stoppage minutes, own-goal beneficiary array, FT-excludes-ET, kickoff parsing).
- `Predictex.Fifa` — **pure** openfootball → FIFA 8-game-round mapping. `Predictex.Fifa.Cohort` —
  **pure** join of FIFA `matchStats.json` cohort → fixtures (`plan/3`; `{utc_date, team-set}` key +
  home/away orientation; **data-verified FIFA↔openfootball alias table** — 8 divergences, the core of `c9s`).
- `Predictex.Leaderboard` — **pure** DB-free aggregator (drives `mix predictex.leaderboard`).
- `Predictex.Standings` — DB-backed leaderboard (`leaderboard/0`), reuses `Scoring`. Entries
  now also carry `bonus_by_round` + per-fixture `fixture_id` so the dashboard reconciles totals.
- `Predictex.Dashboard` — read model for `/predictions`: pure `build/4` + `for_player/2` edge;
  consumes `Standings` as the **single scoring authority** (does no scoring of its own).
- `PredictexWeb.Flags` — team name → flag emoji, keyed on real openfootball strings (⚽ fallback).
- `Predictex.Results.Ingest` — DB ingestion (`plan/1` pure, `commit/1` act; upserts; `@replace_on_conflict` excludes `cohort_*_pct`, so result sync never fights cohort sync).
- **Background jobs (Oban):** `Predictex.Workers.ResultSync` (every 15 min) runs `Ingest.sync_from_url/0`;
  `Predictex.Workers.CohortSync` (hourly) fetches FIFA reference+cohort JSON and applies `Fifa.Cohort.plan/3`,
  **overwriting** `cohort_*_pct` (FIFA is the cohort source; admin `a02` cohort entry is now a vestigial
  stop-gap). Both sync sources injectable for tests (`:result_sync_fun`, `:cohort_source_fun`).
- Contexts: `Tournament` (rounds/fixtures, `round_open?`), `Accounts` (players/auth, `promote_admin/1`), `Predictions` (lockout-aware `create_prediction`).
- Schemas: `Round`, `Fixture`, `Player`, `Prediction` (partial unique index = one booster per player per round).
- Web: `LeaderboardLive` (`/`, public), `MyPredictionsLive` (`/predictions`, auth — read-only:
  rank/total hero, round tabs, pick-vs-actual + points, ⚡ booster, lock state, "no pick
  imported", FIFA link), auth LiveViews (`/players/*`), `HealthController` (`/health`).
  Post-login lands on `/predictions`.

## Deploy
- `.github/workflows/ci-deploy.yml`: **quality** on push/PR to `main`; **deploy** on `v*` tags → build → `ghcr.io/davewil/predictex` → Tailscale SSH to homelab `192.168.1.102` → boot-check → migrate → recreate → `/health` smoke test.
- caddy-docker-proxy serves the domain; TLS via Cloudflare DNS challenge. Postgres on default net only; app on default + proxy.
- **To deploy:** `git tag vX.Y.Z && git push origin vX.Y.Z` (push `main` first to run the quality gate).
- **Secrets set on the repo:** `DEPLOY_HOST`, `DEPLOY_SSH_KEY`, `TS_OAUTH_CLIENT_ID`, `TAILSCALE_AUTHKEY`, `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`, `LEAGUE_INVITE_CODE`.
- `scripts/sync-secrets-from-vault.sh` copies the homelab secrets from Vaultwarden (`bw`).

## Prod ops (run on the host, inside the container)
Releases ship **no Mix** — use release functions, not mix tasks.

**`rpc` vs `eval` — pick by whether the node is running:**
- **`rpc <expr>` → ad-hoc calls against the LIVE node** (Repo + full app already started).
  This is the default for one-off admin/DB ops, e.g. promoting an admin:
  ```bash
  docker compose -f /root/predictex/docker-compose.prod.yml exec app \
    bin/predictex rpc 'Predictex.Accounts.promote_admin("you@example.com")'
  ```
- **`eval <expr>` → ONLY for `Release.*` wrapper fns** (migrations/seeding). `eval` boots a
  fresh BEAM that does **not** start the supervision tree, so the Repo isn't running — a bare
  `Accounts.*` call would crash. The `Release.*` fns work because they start the repo themselves:
  ```bash
  docker compose -f /root/predictex/docker-compose.prod.yml exec app \
    bin/predictex eval "Predictex.Release.sync_results()"   # seed/refresh fixtures (repo started internally)
  ```
- **`rpc` does NOT auto-print the return value** — it only emits what the expression writes to
  stdout. A bare `...start()` runs but shows nothing; wrap in `|> IO.inspect()` to see the result.
  (`Spike.summary/1` prints its own report.) Also: the prompt's `git:(main) ✗` is the dirty-repo
  marker, not a failed command.

## Done (beads issues closed)
Scoring engine · Ecto schemas · DB ingestion + seeds · DB-backed leaderboard (`0ae`) ·
Leaderboard LiveView (`8id`) · CI/CD deploy pipeline (`07o`) · Player auth (`5gw`) ·
**My Predictions read-only dashboard (`79q`)** — spec/plan in `docs/superpowers/{specs,plans}/2026-06-15-my-predictions*`.

## Admin console (`a02`) — SHIPPED in v0.4.0 (2026-06-16)
Full admin console at `/admin` (gated by chained `:require_authenticated` + `:require_admin`).
Spec/plan in `docs/superpowers/{specs,plans}/2026-06-15-admin-console*`. **This is the
playability unlock** — admins can now enter predictions on behalf of players. 237 tests green.
- **Sub-routes:** `AdminLive` (`/admin` landing), `AdminPredictionsLive` (`/admin/predictions`
  — by-player entry grid + by-fixture audit lens), `AdminFixturesLive` (sync button +
  result override + cohort %), `AdminPlayersLive` (list + promote). Nav via
  `PredictexWeb.AdminComponents.admin_nav/1`; an "Admin" link shows in the app nav for admins.
- **Domain added:** `Predictions.admin_upsert_prediction/1` (single-fixture, no lockout,
  transactional booster-clear), `admin_save_round_predictions/3` (sparse-grid batch;
  booster-on-blank errors), `list_fixture_predictions/1`; `Accounts.set_player_admin/2`;
  `count_players/0` / `count_fixtures/0`.
- **Sync is network-free in tests** via injectable `:admin_sync_fun` (config/test.exs stub).
- **Reviewed:** Phases 1–3 two-stage subagent review; Phases 4–7 consolidated review
  (`583a4ce`); plus a full `/code-review` scoped `6e05836..HEAD` which caught and fixed a
  booster-on-blank data-loss bug (`6f95bc4`). `a02` closed.
- **Smoke-tested ✓** (real browser, confirmed working). `v0.4.1` followed with a fix: first-scorer
  (team/player) inputs now show **only for knockout rounds** (group = scoreline only, per rules.md §2;
  scoring already gated it).

## Next (beads open — run `bd ready` / `bd list`)
- **`xox` member self-import — CODE COMPLETE & REVIEWED; one gate left: manual real-session
  validation.** Group-stage scoreline+booster self-import shipped as code (5 tasks, subagent-driven,
  two-stage review each + final integration review = Ready; 275 tests green; commits `1098f4a..097a09b`,
  local/unpushed). Thin bookmarklet (rounds 1..3 → `{round,matchId,homeScore,awayScore,booster}`) →
  `/import` (`ImportLive`): colocated `FifaFragment` hook reads the URL-fragment payload → server
  fetches `rounds.json` (`Fifa.Reference`) → pure `Fifa.Import.plan/3` (composite `{round,matchId}`
  crosswalk via shared `Fifa.Crosswalk`) → preview/confirm → `admin_save_round_predictions/3` for the
  logged-in member. Paste-JSON fallback included. **REMAINING:** run the bookmarklet end-to-end in a
  real authed FIFA session into a `/import` preview (popup-blocker, fragment size, await-all-fetches)
  — the spec's acceptance criterion; CI cannot cover it. Spec/plan:
  `docs/superpowers/{specs/2026-06-16-xox-fifa-import-design.md,plans/2026-06-16-xox-fifa-import.md}`;
  spike: `docs/superpowers/research/2026-06-16-xox-fifa-import-spike.md`.
- `i9k` **xox knockout import** + first-scorer matching (deferred until knockout rounds populate).
- `tvs` xox: derive bookmarklet import URL from endpoint config (today `@import_url` is hardcoded; P4).
- `0yn` Admin **by-fixture inline editing** (the by-fixture lens is audit-only today; spec wanted
  inline save via `admin_upsert_prediction/1`, which has no UI caller yet).
- `a4j` Cache/scope `Standings.leaderboard/0` (recomputed per dashboard load; fine at current scale).
- `c9s` Flags/team-names: the FIFA↔openfootball **alias map is now done** (in `Fifa.Cohort`); only the
  openfootball name-snapshot + regression test remain.
- `08p` Harden `Predictions.save_round_row/3` vs direct-API misuse (P4; not UI-reachable today).

## Earlier milestones (shipped)
- **`a02` admin console** (v0.4.0/v0.4.1) · **`mt6` automated result-sync** + **`7ux` FIFA cohort
  auto-sync** (v0.5.0, Oban). Specs/plans in `docs/superpowers/{specs,plans}/2026-06-15-admin-console*`,
  `2026-06-16-result-sync-automation*`, `2026-06-16-cohort-sync*`.
- **Recent (v0.11.x, see "Live right now"):** `rfm` auto-capture · `fb5` per-viewer tz · `afm`+`4zu` live
  CTA + recap · `vg7` countdown · `cvx`/`d17` KO window. **Dev gate:** `unx` lefthook gate · `kvo` credo+sobelow.

## Conventions & gotchas (learned the hard way)
- **Tracking is beads (`bd`)**, not TodoWrite/markdown TODOs. `bd ready`, `bd show <id>`, `bd update <id> --claim`, `bd close <id>`.
- **Commit autonomously when green; push and tag/push are the user's explicit call** —
  never auto-push, even at session end (commit, report it's local, await "push"). See
  CLAUDE.md → "Conventions & Patterns → Commit / push / deploy boundary". Trunk-based on `main`.
- **`force_ssl` is compile-time** (`config/prod.exs`) — never set it in `runtime.exs` (mismatch aborts the release boot; this bit us — v0.1.0/v0.2.0 failed on it).
- **Magic-link/email auth is DORMANT**: backend kept, UI hidden, for a future email upgrade. Re-enabling needs a mailer + SPF/DKIM/DMARC.
- Feature workflow used: brainstorm → spec (`docs/superpowers/specs/`) → plan (`docs/superpowers/plans/`) → subagent-driven execution.
- Known debt: `unconfirmed_player_fixture` + magic-link tests exercise an unreachable state (tied to dormant email) — clean up when the email epic lands. Real-browser auth click-through not yet done.

## Docs map
- `docs/rules.md` — game rules + §9 scoring/data contract (source of truth).
- `docs/plan.md` — original (Ultraplan) implementation plan.
- `docs/runbooks/deployment.md` — deploy, secrets, prod ops.
- `docs/superpowers/specs/2026-06-15-auth-design.md` + `plans/2026-06-15-auth.md` — auth.
- `docs/superpowers/{specs,plans}/2026-06-15-admin-console*` — admin console (`a02`).
- `docs/superpowers/{specs,plans}/2026-06-16-result-sync-automation*` — `mt6`.
- `docs/superpowers/{specs,plans}/2026-06-16-cohort-sync*` — `7ux`.
- `docs/superpowers/research/2026-06-16-xox-fifa-import-spike.md` — **`xox` spike** (FIFA endpoints,
  data model, crosswalk, three integration forks).
- `docs/superpowers/{specs,plans}/2026-06-16-xox-fifa-import*` — **`xox` design + implementation plan**
  (member self-import; group-stage; server-side composite-key crosswalk; manual-validation gate).
- `docs/superpowers/{specs/2026-06-17-live-buzz-design.md,plans/2026-06-17-live-buzz.md}` — **Live Buzz /
  Live Scores (`c46`)** design + 9-task plan (FIFA live feed, `live_*` columns, `:live_buzz` flag,
  `Standings.project/3`, `/fixtures/:id` PubSub drill-down). See "Continue here" up top.
- **bd memory `fifa-v3-live-api-contract`** — decoded FIFA v3 live API (endpoints, score path, Type/own-goal,
  scorer-name join). `bd memories fifa`.
- `priv/examples/league.sample.json` — sample league file for the DB-free `mix predictex.leaderboard`.
