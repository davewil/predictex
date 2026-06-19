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
- **Latest deployed tag:** `v0.11.4`. Recent: **v0.11.0** auto-start unified live capture (`rfm`);
  **v0.11.1** server-side per-viewer kickoff times (`fb5`) + live-game CTA on `/predictions` (`afm`);
  **v0.11.2** knockout ET/pens capture window + `is_live` auto-clear sweep (`cvx`/`d17`);
  **v0.11.3** `/predictions` live CTA opens 30 min pre-kickoff → live → post-match recap (`4zu`);
  **v0.11.4** next-match countdown banner on `/predictions` (`vg7`, ungated — low-impact).
  `:live_buzz` flag is **ON** in prod.
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

## ⏵ Continue here (2026-06-18)
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

**NEXT — recommended (`bd ready`):**
1. **`predictex-hco` (P2, deadline 2026-06-28)** — knockout readiness. Externally gated: FIFA publishes the
   32 KO `fifa_match_id`s only after the group stage resolves, then backfill via `Fifa.LiveIds.assign`
   (relates `i9k`). ⚠️ **VERIFY before 2026-06-28** (carried from `cvx`): confirm the openfootball feed does
   NOT publish `ft` (→ `status: :completed`) mid-match for knockouts — if it does, `clear_stuck_live/1`'s
   status branch flickers (benign) rather than blacks out the buzz. cvx note has the full reasoning.
2. **Remaining review backlog (P3):** `uhf` (centralize FunWithFlags reset in DataCase/ConnCase → lets 5
   flag tests go async, faster gate), `r90` (extract shared admin flash/reload helper), `bl8` (Live.Updater
   rescue: let-it-crash vs justify+test). (`y58` CSP header — DONE: strict hash-based CSP on the :browser
   pipeline, browser-verified, sobelow Config.CSP retired.)
3. **`predictex-i1s` (P3)** — match replay engine; replay a recorded capture onto a demo fixture. ⚠️ England
   v Croatia has **0 captures** (pre-`rfm`, lost to the manual-arm gap) → not replayable; guard zero-row
   match_ids (documented on i1s). Spec `docs/superpowers/specs/2026-06-17-match-replay-demo-design.md`.

**DEPLOY:** tag `vX.Y.Z` (additive; no migration so far). **Do NOT deploy mid-capture** — the container
recreate interrupts the running producer chain (the `*/5` cron re-arms within ~5min, but you lose frames).
Wait for the in-progress match to finish.

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
- **367 tests** green (incl. 7 property laws). **The gate is `mix precommit`** (compile --warnings-as-errors,
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
- **Commit/push only when asked.** Trunk-based on `main`.
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
