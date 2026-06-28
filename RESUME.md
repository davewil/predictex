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
- **Latest deployed tag:** `v0.11.21` (deployed + verified 2026-06-28 ~18:48 UTC: Deploy success **3m18s**,
  `/health`+`/`+`/bracket` 200, valid TLS, `/bracket` renders "As it stands"/"Round of 32"; tagged ~T-20 before
  the first R32 kickoff, clear of capture) — **`predictex-u4k`** first-player-to-score picker (app-styled modal,
  `players.json` source) **+ `dum`** (e5o v2 both-placeholder R32) **+ the tidy-up batch**. u4k: `Fifa.Players`
  squad join + ETS cache (lazy/boot-warm/**negative-cache**/keep-stale) + `Workers.PlayersSync` (`*/30`) +
  `first_scorer_fifaid` column + scoring **accent-fold** + flag-gated modal picker writing
  `first_scorer_player`+`first_scorer_fifaid`. ✅ **Cache verified warm in prod** 2026-06-28 ~18:55 UTC via rpc:
  `:ets.info(Players.Cache, :size)` = **49** (48 squads + `:__loaded__` sentinel), Brazil/France `for_team` =
  26/26 (full rosters) — boot-warm succeeded. So flag-on + an editable R32 card → members get a populated picker. ⚠️ **Known scoring gap (deferred `i9k`):** ~16% of correct first-player
  picks (mononyms — Mbappé→"Kylian Mbappé") still score 0 until exact-`fifaId` scoring lands; accent-fold
  recovers the ~12% accent-only cases. See `bd remember fifa-vs-openfootball-scorer-names`.
- **Prior deployed tag:** `v0.11.20` (deployed + **verified in prod** 2026-06-27 ~18:30 UTC: Deploy success in
  3m24s, **no migration**, `/health`+`/`+`/bracket` 200, valid TLS; tagged with no match capturing) —
  **`predictex-ahi`**: team-identity **no-downgrade guard** in `Ingest`. e5o (v0.11.19) was filling R32
  placeholder slots from FIFA but the fills **didn't stick** — `Fixture` `@castable` includes `team1/team2`, so
  every `ResultSync` (15-min) cast openfootball's *still-placeholder* name (`USA team2 "3B/E/F/I/J"`) back over
  e5o's filled real name (`preserve_settled` only guarded result fields). `preserve_resolved_teams/2` makes team
  identity **monotonic** (placeholder→real only; openfootball keeps real→real authority). **PROD-VERIFIED:**
  parsed `/bracket` slot ids — fixture 74 Germany v **Paraguay** + fixture 81 USA v **Bosnia & Herzegovina** both
  filled and **held 20+ min across ResultSync cycles**. Root cause via systematic-debugging (failing test
  reproduced the revert); advisor-reviewed. **Known anchored-only limit (visible in prod):** a both-placeholder
  fixture FIFA has resolved (e.g. fixture 77 France `1I` v Sweden `3rd·C/D/F/G/H`) stays unfilled until
  openfootball resolves its winner side — deferred enhancement, not a bug.
- **Prior deployed tag:** `v0.11.19` (deployed + verified 2026-06-27 ~13:10 UTC: Deploy success in 3m53s,
  **no migration**, `/health` 200, anon `/` 200, `/bracket` 200, valid TLS; tagged with no match capturing) —
  bundles **`predictex-e5o`** (FIFA-bracket third-placed R32 resolution) **+ `predictex-kob`** (next-match
  banner fix). **`e5o`:** a new self-arming Oban worker `Workers.KnockoutTeams` (cron `*/10`, stop-before-fetch)
  fills resolved team names into R32 **placeholder** slots from FIFA `rounds.json` ahead of openfootball — e.g.
  USA's `3B/E/F/I/J` → `Bosnia & Herzegovina` the moment FIFA locks it. **Anchored-only:** fills only a fixture
  with exactly one placeholder side (the resolved side anchors orientation AND validates the slot match);
  **no-downgrade** (writes only `team1`/`team2`, only placeholder→real, never overwrites an
  openfootball-resolved name — openfootball stays authoritative, reclaims on its `source_num`-keyed re-sync).
  Pure `Fifa.KnockoutTeams` (`canonical_index/1` + `plan/3` slot-match via `Crosswalk.slot_key`, name-normalize
  via the `Crosswalk` alias table). **`kob`:** `Dashboard.next_matches/2` returns all fixtures tied at the
  soonest kickoff (was `List.first` — only one of two simultaneous next matches showed); plural "Next matches"
  banner. 562 tests. **▶ OBSERVE:** within ~10 min of deploy, the worker should fill the resolved thirds —
  watch `/bracket` flip USA v `3B/E/F/I/J` → USA v Bosnia (server log line `knockout team backfill:`).
  **▶ STILL REMAINING = flag rollout (user's call):** the native game is **DARK for members** —
  `:native_ko_entry` is admin-group-only; `rpc 'FunWithFlags.enable(:native_ko_entry)'` opens it to all.
- **Prior deployed tag:** `v0.11.18` (deployed + verified 2026-06-26 ~18:01 UTC: Deploy success in 3m44s,
  **no migration**, `/health` 200, anon `/` 200, valid TLS, **`/bracket` renders** "As it stands"/"Round of
  32"/group tables) — bundles **`predictex-80k`** (per-fixture native R32 KO unlock — native KO entry now
  gated PER FIXTURE not per round; `round_open?` retired; `:editable` when flag-on + both teams resolved +
  kickoff future, `:locked` read-only + `/fixtures` CTA when kicked-off, `:pending` "⏳ awaiting teams" when a
  slot is still a placeholder; booster commit-at-kickoff `{:error,:booster_locked}`; shared
  `Knockout.resolved_team?/1` is the single resolution truth across `Bracket` + write path) **+ `predictex-7qu`**
  (public `/bracket` "as it stands" projected R32 page). **▶ REMAINING = flag rollout (user's call, ops/no-code):**
  the game is still DARK for members — `:native_ko_entry` is enabled only for the `:admins` group. Roll out with
  `rpc 'FunWithFlags.enable(:native_ko_entry)'` for ALL members → resolved R32 matches become predictable
  FIFA-style. Kill switch = `rpc 'FunWithFlags.disable(:native_ko_entry)'`, no redeploy.
- **Prior deployed tag:** `v0.11.17` (deployed + verified 2026-06-25 14:13 UTC: Deploy success, no migration,
  `/health` 200, anon `/` 200, `native_ko_entry` resolves `false` — ships OFF, game dark) — **`predictex-5q6`**:
  native KO entry gated behind the `:native_ko_entry` FunWithFlags flag. Render gate (`editable_round?/2`) +
  independent write-path gate (`save_round_predictions/5` → `{:error, :feature_disabled}`) both check
  `FunWithFlags.enabled?(:native_ko_entry, for: player)`; `FunWithFlags.Group` for `Player` resolves `:admins`
  off `is_admin` for staged rollout. No migration (flag store exists from `:match_replay`). **▶ REMAINING =
  operational rollout (user's call):** `rpc 'FunWithFlags.enable(:native_ko_entry, for_group: :admins)'` →
  verify the native R32 form as an admin on the **28-Jun** bracket → `rpc 'FunWithFlags.enable(:native_ko_entry)'`
  for all. Kill switch = `disable`, no redeploy.
- **Prior deployed tag:** `v0.11.16` (deployed + verified 2026-06-24 18:21 UTC: Deploy success, no migration,
  `/health` 200, anon `/` 200; tagged clear of the 20:00 capture window) — **`predictex-2mh` (CLOSED)**:
  prediction writes now broadcast `:fixtures_changed`. Only the result-settle paths (Ingest, FifaFallback,
  LiveScore) emitted the coarse `Tournament.broadcast_change/0` signal; the four prediction writers
  (`create_prediction`, `admin_upsert_prediction`, `admin_save_round_predictions`, `save_round_predictions`)
  did not — so an admin entering/importing a prediction on an **already-completed** fixture (`admin_upsert`
  has no lockout; import writes past rounds) changed standings while open `/predictions` sessions stayed stale
  until the next settle. A private `broadcast_on_success/1` wraps all four; only `{:ok, _}` broadcasts
  (failed/locked writes don't). Found while scoping `0ft`/`a4j` (both DEFERRED — see below); the real win was
  this latent staleness fix. TDD: 5 tests; 512 green.
- **Prior deployed tag:** `v0.11.15` (deployed + verified 2026-06-24: Deploy success, no migration,
  `/health` 200, anon `/` 200) — **`predictex-4ez` (CLOSED)**: per-fixture scoring breakdown chips +
  risky-pick banner on the FixtureCard. `Scoring.score/3` already exposed `:components`; `Dashboard.build/4`
  was projecting it down to just `fixture_total` at the boundary — now it carries the full `result` through
  `fixture_view`, which derives `breakdown` (non-zero scoring lines as labelled+toned chips in the canonical
  scoring-legend order) + `risky_pct` (cohort share of the predicted winner that fired the risky bonus, read
  from the same integer field `Scoring` used). `fixture_card/1` renders the chips + a "Risky pick paid off —
  only N% backed it" banner. **Booster reconciliation:** chips stay BASE values (matching the static legend)
  and a `×2` badge bridges to the doubled headline `points`. code-reviewer APPROVED; 507 tests. ⚠️ Chips +
  banner show on the **auth-gated `/predictions` for SETTLED fixtures only** — eyeball one real settled
  fixture to confirm render.
- **Prior deployed tag:** `v0.11.14` (deployed + verified 2026-06-23: Deploy success, no migration,
  `/health` 200, anon `/` 200, `Workers.KnockoutIds`/`Crosswalk.slot_key` live, KO coverage `0/32`
  pending FIFA bracket) — **`predictex-hco` WS1**: self-arming knockout `fifa_match_id` backfill.
  `Workers.KnockoutIds` (cron `*/10`) stop-before-fetch → fetch `rounds.json` + `LiveIds.assign` the
  moment FIFA publishes the bracket; `LiveIds.plan` skip-already-assigned + a KO-only date+time **slot
  fallback** (`Crosswalk.slot_key`, proxy-verified to the minute on all 72 group matches) robust to
  openfootball team-resolution lag; group stays name-join. **WS1 verifies on 28 Jun** (KO rounds populate
  → worker assigns → `32/32` → first KO captured through ET/pens, `is_live` clears). `g8m` closed (no-dup
  verified at partial bracket resolution). **▶ Next KO item:** `predictex-cij` (P3, per-fixture live/recap
  gate within an open KO round); `predictex-i9k` (xox KO import + first-scorer).
- **Prior deployed tag:** `v0.11.13` (deployed + verified 2026-06-23: Deploy success, no migration,
  `/health` 200, anon `/` 200, new code live in prod) — bundles **`predictex-ius`** (weather-proof live
  capture: `Workers.LiveScoreSync` keeps capturing while `is_live` so a weather-suspended match —
  FIFA `MatchStatus 11` — is captured to its real finish instead of being cut off at kickoff+210min;
  `clear_stuck_live` backstop decoupled to `@abandon_min`=360) **+ `predictex-iy1`** (FIFA-capture result
  fallback: `ResultSync` settles a played **group** fixture provisionally from the captured FIFA finished
  frame `MatchStatus 0` when openfootball lags — `Predictex.Results.FifaFallback`; plus an `Ingest`
  no-downgrade guard so a `:completed` fixture never reverts to `:scheduled` via a no-result sync,
  killing the revert flicker. Both closed. Spec/plan: `docs/superpowers/{specs,plans}/2026-06-23-iy1-*`).
  ⚠️ France v Iraq was settled manually 3-0 (admin override) before the fallback shipped — openfootball
  still has no result for it; the fallback covers matches going forward (its finished frame needs the ius
  capture fix, which this same tag deploys).
- **Prior deployed tag:** `v0.11.10` (deployed + verified 2026-06-20: Deploy success, migration
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
  - ⚠️ **This is changing for the KNOCKOUTS.** The Knockout-Game thread (see "Continue here") makes
    `/predictions` **editable** for the open knockout round — members predict natively in-app from R32. Group
    stage stays as described above (frozen, FIFA-import). **Phase 1 is DEPLOYED (rode the v0.11.x tags); ⚠️
    verify the editable R32 entry actually renders — see "Continue here".**

## ⏵ Continue here (2026-06-28) — `predictex-u4k` CODE-COMPLETE (committed LOCAL); DEPLOY is the user's call

The native KO game is **LIVE for all members** — `:native_ko_entry` flag switched ON in prod 2026-06-28
(user ran `rpc 'FunWithFlags.enable(:native_ko_entry)'`). Members can predict resolved R32 matches natively.
Latest deployed tag **`v0.11.20`** (e5o third-placed + ahi guard, prod-verified). On origin-but-UNDEPLOYED:
`dum` (e5o v2 both-placeholder) + the tidy-up batch (`kob`/`94u`/`57t`/`cfi`/`34w`). **`v0.11.21` would bundle
those + u4k.** **Prod cleanup done:** the 6 demo players purged; only the real admin remains.

### ✅ DONE this session: `predictex-u4k` first-player picker — CODE-COMPLETE, committed LOCAL (10 commits `fe13e33`(plan)..`2de046a`)
Subagent-driven 7-task TDD + opus whole-branch review. **594 tests green, full gate clean. NOT pushed/tagged.**
- **Shipped:** `Fifa.Players` (pure `players.json`⋈`squads.json` join, keyed `Crosswalk.norm(team)`) · `Fifa.Players.Cache`
  (supervised ETS, lazy-load + boot-warm + `refresh/0` + **negative-cache** cold-load failure + keep-stale + non-destructive
  swap) · `Workers.PlayersSync` (`*/30` cron freshness tick) · **`first_scorer_fifaid`** column + intake (predictions-side
  half of `i9k`) · scoring `norm/1` **accent-fold** · `MyPredictionsLive` app-styled modal picker (2-team toggle / search /
  name·position·goals / "No first scorer") + `.RoundEntry` hook writing sr-only `first_scorer_player`+`first_scorer_fifaid`
  (flag-gated render). Plan: `docs/superpowers/plans/2026-06-28-first-player-picker.md`.
- **⚠️ KEY DATA-CONTRACT FINDING (drove scope; verified, not in original spec):** the picker stores a FIFA `shortName` but
  scoring matches **openfootball**'s scorer name via `trim+downcase`. Cross-source test (2022 OF goals × 2026 FIFA names,
  ~68 same-player pairs): only **~72%** match; **~12%** accent-only (the accent-fold now recovers these); **~16%** structural
  (Mbappé→"Kylian Mbappé", Rashford, Mac Allister — mononyms). So v1 **stores `first_scorer_fifaid`** so the exact-id fix
  isn't lost, and accent-folds. The structural ~16% is a **KNOWN gap, deferred by user decision to `i9k`** (exact-`fifaId`
  actual-side scoring). Without `i9k`, those correct picks still score 0.
- **▶ DEPLOY GATE (opus review) — when you choose to ship `v0.11.21`:** the cold-cache path does a synchronous FIFA fetch on
  the render path; it's dormant if boot-warm succeeds. **Tag before 20:00 UTC kickoff ONLY after confirming the post-deploy
  log line `players cache: N squads loaded` on a healthy feed**, then `rpc 'Predictex.Fifa.Players.Cache.refresh()'` to
  force-warm. Don't tag mid-capture. **Manual eyeball before tag:** `iex -S mix phx.server` → `FunWithFlags.enable(:native_ko_entry)`
  + `Fifa.Players.Cache.refresh()` → `mix predictex.preview_knockout` → open an editable R32 card → modal open/toggle/search/select
  → submit → reload → pick persists. (Phone over Tailscale for touch.) **I decide production-ready — code is committed local, awaiting your "push".**
- **Follow-ups filed:** `predictex-6ea` (P4 — accent-fold the picker *search box*; minor test hardening) · `i9k` (exact-`fifaId`
  scoring — the structural-divergence fix; u4k shipped its predictions-side column).

> **Other open:** `predictex-hco` WS1 — confirm `KO fifa_match_id: 32/32` once FIFA publishes the bracket, then
> first KO capture through ET/pens with `is_live` clearing (closes `hco`). `predictex-i9k` (KO scorer import +
> exact-`fifaId` matching) is the scoring-data sibling of u4k — the `players.json` `fifaId` ↔ `/detail` `IdPlayer`
> join (spike 8/8) is the path.

> **What 80k changed (shipped):** native KO entry is now gated **per fixture**, not per round. `round_open?`
> is **retired**. A knockout fixture is `:editable` when the flag is on AND both teams are resolved (real
> names, not `1A`/`3A/B/C/D/F`/`W89` placeholders) AND kickoff is future; `:locked` (read-only + `/fixtures`
> CTA) when resolved+kicked-off; `:pending` ("⏳ awaiting teams") when a slot is still a placeholder. Booster
> is **commit-at-kickoff** (`{:error, :booster_locked}`, no constraint crash). Shared `Knockout.resolved_team?/1`
> is the single resolution truth (Bracket + write path both consume it). Member self-serve R32 entry now works
> the moment FIFA/openfootball resolve each match — no 28-Jun whole-round wait.

### ✅ DONE this session (2026-06-26 #2) — all committed + PUSHED (origin/main `15438d2`)
- **`predictex-80k` SHIPPED + pushed (CLOSED)** — per-fixture native R32 unlock. 5 commits
  `a905510..1950e28` (`142b090`,`fc8fdd9`,`f210041`,`bd4600f`,`1950e28`), subagent-driven 5-task TDD, every
  task spec-✅/Approved, **opus final whole-branch review = Ready to merge** (no Critical/Important; all
  cross-task seams verified). 547 tests green, full gate clean. **DEPLOYED + verified as `v0.11.18`** (bundled
  with `7qu`; pre-deploy gate green, deploy 3m44s, no migration, `/health`+`/`+`/bracket` all 200). Flag
  rollout to all members is the one remaining step (START HERE above).
  4 Minor follow-ups filed (`94u` `:pending` card shows raw placeholder not friendly label; `cfi` booster
  guard runs a SELECT on no-booster saves; `34w` test doc-rot (stale `round_open?` comments + dead
  predecessor scaffolding); `57t` `bracket.ex` `@third` dead captures) — all P4. `cij` **narrowed** (its
  write-safety + per-fixture render are delivered here; now inline-recap-only nicety).
- SDD ledger section: `.superpowers/sdd/progress.md` ("predictex-80k" + "ALL 5 TASKS COMPLETE" + final review).

### Prior session (2026-06-26 #1) — context for the above
- **`predictex-5q6` DEPLOYED `v0.11.17`** — `:native_ko_entry` flag dark-ships native KO entry (see the
  "Live right now" block + the detailed block below). **Flag is currently enabled for the `:admins` group
  in prod** (the user set it via `/admin/feature-flags`; verified admin→true, member→false). 80k replaced the
  `round_open?` round-gate it shipped with a per-fixture gate.
- **`predictex-7qu` BUILT (local→now PUSHED, NOT deployed)** — public `/bracket` "as it stands" projected R32 page:
  pure `GroupTables` → `Bracket.Thirds` (best-8-of-12) → total `Bracket` (resolve_slot/build/view) →
  `BracketLive` on `:fixtures_changed`. Candidate-set thirds (the 495-row FIFA table was spiked + rejected —
  `docs/superpowers/research/2026-06-25-bracket-thirds-table-spike.md`); exact thirds arrive via the 28-Jun
  ingest. 8 commits, subagent-driven + opus final review (Ready-with-fixes → the one must-fix, a tautological
  live-update test, FIXED). 542 tests green. **Follow-ups:** `predictex-v4k` (P3 — bracket renders `{:exact}`
  even for 0-game/provisionally-tied slots; surface a provisional badge), `predictex-7t7` (P4 minor test/regex).
- **`predictex-80k` is now SHIPPED + pushed** (see "DONE this session #2" above) — Task 1 created
  `Predictex.Knockout` and refactored `Bracket` onto it, so `7qu` and `80k` now share the one
  `Knockout.resolved_team?/1` resolution predicate on `main`.

---

### `predictex-5q6` detail (DEPLOYED `v0.11.17`) — the flag mechanism `80k` builds on
**Flag state in prod NOW:** enabled for the `:admins` group (user set it via `/admin/feature-flags`;
verified admin→`true`, member→`false`, global→`false`). Final rollout to all members is `rpc
'FunWithFlags.enable(:native_ko_entry)'` — but do that AFTER `80k` lands (per-fixture unlock) so members
get the FIFA-style per-match experience, not the round-level one. Kill switch =
`rpc 'FunWithFlags.disable(:native_ko_entry)'`.

**Shipped in `v0.11.17` (commit `19e99de`) — gate green (523 tests, credo clean), deployed + verified:**
- **`FunWithFlags.Group` for `Player`** (`player.ex`): `:admins` resolves off `is_admin` (matches both
  `:admins` and `"admins"` since FWF normalizes group names to strings). Group-only is sufficient — no
  Actor impl needed because no per-actor gates are used; `player_flags_test` proves `enabled?(for: player)`
  doesn't crash without Actor.
- **Render gate** (`my_predictions_live.ex`): `editable_round?/2` now ANDs
  `FunWithFlags.enabled?(:native_ko_entry, for: player)` with knockout + `round_open?`. Flag off →
  read-only FIFA-import grid for everyone. `native_ko_enabled?/1` is the single flag-check source.
- **Independent write-path gate** (defense in depth): `Predictions.save_round_predictions/5` takes an
  `enabled?` boolean and returns `{:error, :feature_disabled}` before any DB work. The LiveView resolves
  the flag and passes it down; the context stays FunWithFlags-agnostic. Composes with the existing
  round-membership + lockout write-auth.
- **TDD:** `player_flags_test.exs` (direct Group + `for_group: :admins` resolution; **`async: false`** to
  isolate the global FWF ETS cache from `MyPredictionsLiveTest`); flag-off render stays read-only on an
  OPEN KO round; the 3 editable-KO tests now `@tag :native_ko` (enable + `Cache.flush/0` `on_exit` — the
  compile-env-safe isolation, NOT a `config/test.exs` `:cache` override); context-level disabled rejection.
- **No migration** (flag store exists from `:match_replay`). **Default off = game dark.**

**▶ NEXT — pushed + deployed (`v0.11.17`). Remaining is the rollout (top of block) + Phase 2 gaps:**
`cij` (per-fixture live/recap gate within an open KO round), `i9k` (KO first-scorer import), deferred
player-picker (squad-endpoint spike / free-text fallback) — all sequence after the rollout.

> ⚠️ **Dev-eyeball gotcha (NEW):** `mix predictex.preview_knockout` + `mix phx.server` now shows the
> **read-only** grid even after the predecessor settles — correct, because `editable_round?/2` also gates
> on the flag and it's **unset (off) in the dev DB**. To eyeball the native form locally: `iex -S mix phx.server`
> then `FunWithFlags.enable(:native_ko_entry)` (or `FunWithFlags.enable(:native_ko_entry, for_group: :admins)`
> + log in as an admin to exercise the group path).

---

## ⏵ Prior session (2026-06-25) — native KO entry shipped to `main` (UNDEPLOYED)

Cross-machine pickup on the new Omarchy box. Set up the toolchain (mise erlang 28.5 / elixir
1.20.1-otp-28), deps, a disposable Docker Postgres (`predictex-dev-pg`), seeded dev DB — then advanced
**`predictex-2ww` (native in-app KO predictions)** sub-goal (a) and refined the entry UX live.

**Pushed to `main` (3 commits, `fdcac41..a1e5654`) — NOT deployed (no tag):**
- `454c1fa` **spec** — `docs/superpowers/specs/2026-06-24-knockout-preview-dev-task-design.md` (filename dated
  24 Jun; authored just before midnight).
- `8f1c427` **`mix predictex.preview_knockout`** — dev/test-only task: settles the first KO round's predecessor
  (last group round) via the real `Tournament.update_fixture/2` admin path so `round_open?(R32)` flips locally
  and the native form can be eyeballed before 28 Jun. Idempotent, fails loud, 5 TDD tests. Run:
  `mise exec -- mix predictex.preview_knockout` then `mise exec -- mix phx.server`.
- `a1e5654` **native KO entry UX** — on the editable `/predictions` KO form: speedy single-digit goal entry
  (0-9, no spinners, auto-advance home→away→next card, backspace steps back; server bound `Prediction` goals
  ≤ 9), 4-up responsive grid (matches the read-only my-picks grid), first-scorer + booster as **image toggle
  buttons** (flags / ⚡, pure-toggle, booster round-exclusive) driven by one colocated `RoundEntry` hook
  writing **sr-only** inputs (preserves the `phx-submit` field names → existing save tests pass), mobile polish
  (44px targets, numeric keypad, GBoard-reliable input-event backspace, no keyboard auto-pop on touch).
  **Verified desktop + real phone over Tailscale; user signed off "UX is fine."** 519 tests green.

**Current gating:** the native form is controlled ONLY by `editable_round?/1 → round_open?/1` (auto-opens
28 Jun). There is **no feature flag yet** — that is the next deliverable (below) so the full feature can be
dark-shipped + rolled out to admins first.

**⚠️ Machine caveats (this Omarchy box):** `lefthook` NOT installed → commit gate not auto-enforced (ran
`mix precommit` manually before each commit — install lefthook to restore). `bd` build lacks CGO → Dolt
unusable, CLI wedged; read `issues.jsonl` directly and **could NOT update beads here** (run the commands in
"★ BEADS" below on the Dolt machine). Disposable Docker Postgres `predictex-dev-pg` + dev server may still be up.

### ★ DONE (delivered in `19e99de`, see the top block) — the feature-flag delivery plan (`predictex-5q6`)

> ✅ Steps 1–4 below are **implemented + committed local** (`19e99de`). The rollout (step 6) is the
> deploy-time NEXT in the top block. Step 5 (Phase 2 gaps) is still open. Kept here as the executed spec.

#### Original plan — deliver the full native-KO feature behind a feature flag (`predictex-2ww`/`5q6`)

Ship the complete native KO game so it can be **dark-shipped and rolled out in stages** (off → admins → all
members), decoupled from the automatic 28-Jun `round_open?` cutover. Use **FunWithFlags** (the repo's retained
dark-ship mechanism — dep + `/admin/feature-flags` dashboard; `:match_replay`/`:live_buzz` were the prior
users). Flag: **`:native_ko_entry`**. Design is settled — go straight to `writing-plans`/TDD.

1. **Flag + admins group gate.** Implement `FunWithFlags.Group` for `Player` so `:admins` resolves to
   `player.is_admin`, enabling "enable for admins first" without a redeploy.
2. **Gate the render** — `editable_round?/1` (`my_predictions_live.ex`) becomes
   `FunWithFlags.enabled?(:native_ko_entry, for: current_player) AND stage == :knockout AND round_open?`.
   Flag off → read-only FIFA-import grid for everyone (game dark); on → native entry. Thread the current player
   in via the socket's `current_scope`.
3. **Gate the write path too (defense in depth)** — `save_round` handler / `Predictions.save_round_predictions/4`
   must reject when the flag is off for that actor, so crafted params can't bypass a dark flag. Compose with the
   existing round-membership + lockout write-auth at the `parse_pick_rows/2` boundary (arch #4).
4. **Tests (TDD)** — flag off × {render hidden, write rejected} and flag on × {render shown, write saved}.
   ⚠️ Use the `on_exit` `FunWithFlags.Store.Cache.flush/0` isolation, NOT a `config/test.exs` `:cache` override
   — the compile-env gotcha (see the v0.11.11 note below) passes locally but fails CI.
5. **Phase 2 gaps (sequence after the flag):** `cij` (per-fixture live/recap gate WITHIN an open KO round —
   today a uniform input grid even for kicked-off fixtures; write already safe, cosmetic), `i9k` (KO
   first-scorer import), deferred **player-picker** (squad rosters absent pre-match — needs a squad-endpoint
   spike or free-text fallback).
6. **Rollout:** deploy with `:native_ko_entry` OFF → `FunWithFlags.enable(:native_ko_entry, for_group: :admins)`
   → verify on the real 28-Jun bracket as an admin → `FunWithFlags.enable(:native_ko_entry)` for all. Kill
   switch = disable the flag (no redeploy) — the lever the contracted `:live_buzz` gave up.

Local loop (built this session): `mix predictex.preview_knockout` opens R32 in dev so you can exercise the flag
+ form without waiting for 28 Jun. Phone over Tailscale: `socat TCP-LISTEN:4001,fork,reuseaddr
TCP:127.0.0.1:4000` then `http://<tailscale-ip>:4001` (ufw allows the `tailscale0` interface; phone needs
Tailscale running). `tailscale serve` needs root here, so socat is the path.

### ★ BEADS — run on the Dolt-capable machine (couldn't update from the no-CGO Omarchy box)
```
bd update predictex-2ww --notes "Sub-goal (a) DONE: mix predictex.preview_knockout dev task shipped (8f1c427) — opens R32 locally pre-28-Jun. Native KO entry UX refined + signed off (a1e5654): speedy 0-9 goal entry w/ auto-advance, 4-up grid, image toggle buttons (first-scorer/booster), mobile-ready. On main, undeployed. NEXT: gate behind FunWithFlags :native_ko_entry for staged rollout — see RESUME 2026-06-25 'NEXT'."
bd create --title="Gate native KO entry behind :native_ko_entry feature flag" --type=feature --priority=2 --description="Dark-ship the native KO game: FunWithFlags :native_ko_entry + Player :admins group gate; gate editable_round? render AND save_round_predictions write (defense in depth); TDD with on_exit cache-flush isolation (NOT config/test.exs override). Roll out off->admins->all. See RESUME 2026-06-25 'NEXT'."
```
Then `bd sync`.

---

## ⏵ Continue here (2026-06-24) — prior session (4ez/2mh eyeball reminders below still valid)

Deployed tag is **`v0.11.16`** (see "Live right now") — **shipped `predictex-4ez` then `predictex-2mh` this
session**, both deployed clean (no migration, `/health` 200, anon `/` 200; pre-deploy gate green; live-match
safety confirmed clear before each tag). `main` is pushed and up to date with origin.
- **`4ez`** (v0.11.15): per-fixture scoring breakdown chips + risky banner on the FixtureCard. **One eyeball
  left:** confirm the chips + banner render on the auth-gated `/predictions` for a real SETTLED fixture (CI
  can't cover the authed render).
- **`2mh`** (v0.11.16): prediction writes broadcast `:fixtures_changed` (latent staleness fix — open dashboards
  now re-pull when an admin enters/imports a prediction). Found while scoping `0ft`/`a4j`, which are now
  **DEFERRED** (both premature per their own bead text; revisit triggers + safe-approach notes recorded on
  each bead). **Eyeball (optional):** open `/predictions` in one session, admin-enter a pick in another → the
  first updates without reload.

The next pivotal date is still **28 Jun (R32 starts)** — the KO-cutover items verify themselves then.

### ★ ACTIVE THREAD (cross-machine handoff 2026-06-24) — "go fully native in-app for the knockouts" (`predictex-2ww`)

**Status (UPDATED 2026-06-25): RESOLVED — sub-goal (a) was chosen and DELIVERED.** Preview task + native KO
entry UX shipped to `main` (see the 2026-06-25 block at the top). The brainstorm question below is settled; the
live next step is "feature-flag the full feature" (2026-06-25 ★ NEXT). The (b)/(c) options remain valid future
directions. (`.remember/` is **gitignored**, so this RESUME block is the handoff — don't look in `.remember`.)

**The trigger:** user observed "I'm not seeing the ability to enter predictions." **Diagnosis (confirmed in
code, not a bug):** native KO entry is already BUILT + DEPLOYED (Phase 1) but **gated invisible until ~28 Jun.**
- `/predictions` renders the editable native form only via `editable_round?/1` (`my_predictions_live.ex:377`),
  which is true **only** for `stage: :knockout` rounds where `Tournament.round_open?/1` holds.
- `round_open?/1` (`tournament.ex:45`) requires the **predecessor round fully `:completed`**
  (`round_complete?/1` = every fixture in it `:completed`).
- It's 24 Jun, group stage still running → no KO round open → even selecting the **R32 tab** shows the read-only
  grid. Group rounds are read-only by design (FIFA-import). **Net: right now NO member can natively enter a
  pick anywhere**; the R32 form auto-appears when the last group match settles (~28 Jun).

**What already exists (don't re-design):**
- Spec (advisor-reviewed, locked decisions): `docs/superpowers/specs/2026-06-22-knockout-game-native-predictions-design.md`
- Phase 1 plan: `docs/superpowers/plans/2026-06-22-knockout-game-phase1-foundation.md`;
  FIFA-feed spike: `docs/superpowers/research/2026-06-22-knockout-fifa-feed-spike.md`
- Phase 1 SHIPPED + deployed: editable `/predictions` for the open KO round (scoreline + first-team + booster),
  knockout-only re-based board (`Standings.knockout_leaderboard/0`) + Overall/Knockout toggle on `/`,
  lockout-aware `save_round_predictions/4` with the out-of-round/locked write-auth seam.
- Locked scope decision: **group stage stays frozen/FIFA-import**; native entry is **knockout-only (R32+)**.

**Phase 2 gaps (open beads):** `cij` (per-fixture live/recap gate *within* an open round — today it's a uniform
input grid even for already-kicked-off KO fixtures; write is safe, cosmetic), `i9k` (KO first-scorer import),
deferred **player-picker** (spike verdict: squad rosters ABSENT pre-match from FIFA `/detail` → needs a
dedicated squad-endpoint spike or a free-text fallback; scoring already gates the first-player component).

**DECISION (RESOLVED 2026-06-25):**
- **(a) Make native KO entry testable NOW — ✅ CHOSEN + DONE.** Built `mix predictex.preview_knockout` (opens
  R32 in dev pre-28-Jun) and used it to refine + sign off the native entry UX. Shipped to `main` (see top block).
- **(b) Build the Phase 2 gaps** — `cij` per-fixture gate, then `i9k` / player-picker. Design exists; execution.
  STILL OPEN — sequenced after the feature flag (2026-06-25 ★ NEXT, step 5).
- **(c) Reconsider the gate/UX** — should R32 open as soon as the bracket is known rather than at full group
  completion? A design conversation about the entry model itself. STILL OPEN (future direction).

> ✅ **Resolved this session — the R32 "read-only" screenshot is correct-by-design, not a bug.** `/predictions`
> gates the editable native KO form on `editable_round?/1 → Tournament.round_open?/1`, and a knockout round
> opens only when its predecessor is fully `:completed` (`round_complete?/1`). R32's predecessor is the last
> group round, still mid-flight, so R32 correctly shows the read-only FIFA-import grid; the native form unlocks
> automatically when the group stage ends. The 28-Jun cutover (read-only→editable flip) is now **CI-proven**
> by the new regression test (`e385da9`) — it drives the real `settle → broadcast_change → round_open? flips`
> chain. So "verify native R32 entry renders" is no longer a live-discovery risk; only the FIFA-side pieces
> (`hco` WS1 `32/32`, first-KO capture) still need a real 28-Jun eyeball.

### ★ NEXT SESSION — the 28 Jun knockout cutover
- **`predictex-hco` WS1 (deployed v0.11.14) — VERIFY on 28 Jun.** `Workers.KnockoutIds` (cron `*/10`) self-arms:
  once FIFA publishes the KO bracket in `rounds.json`, it backfills all 32 KO `fifa_match_id`s (name-join + a
  KO-only date+time **slot fallback**, proxy-verified to the minute on all 72 group matches). Watch the log reach
  `KO fifa_match_id: 32/32`, then confirm the first KO (Sun 28 Jun 20:00) captures through ET/pens with `is_live`
  clearing on finish → **closes `hco`**. WS2 already covered (cvx + ius). Currently `0/32` (FIFA KO rounds empty).
- **Knockout Game Phase 1 (native R32 entry) is DEPLOYED** (its commits `8419a2f..f94a779` rode the v0.11.x tags
  from main HEAD). ⚠️ **VERIFY the editable native entry actually renders on `/predictions` for the open R32** — a
  2026-06-23 screenshot showed R32 in the read-only FIFA-import style ("Make / update picks on FIFA"), so confirm
  whether the native scoreline / first-team / booster inputs show for the open KO round or are gated. Phase-2
  follow-ups: `cij` (P3, per-fixture live/recap gate within an open KO round), `i9k` (KO import + first-scorer),
  and the deferred player-picker (squad rosters ABSENT pre-match — needs a squad-endpoint spike or free-text
  fallback; regulation goals = `Period∈{3,5}`, `Period 10`=finished-regulation, ET period values UNKNOWN until 28 Jun).

### ★ SHIPPED THIS SESSION (2026-06-23) — laptop-handoff batch (committed + pushed, NOT deployed)
- **28-Jun cutover regression test** (`e385da9`) — drives the read-only→editable KO flip in CI (settle last
  group fixture → `broadcast_change` → `round_open?` flips → editable form renders + saves). Converts the
  "eyeball it live on match day" risk into a CI invariant. See the ✅ note in "Continue here".
- **`predictex-c9s` CLOSED** (`506aa8d`) — `PredictexWeb.Flags` golden-file regression. Frozen snapshot of the
  openfootball 2026 feed's distinct team-name set (`test/support/fixtures/openfootball/team_names_2026.txt`,
  109 strings @ 2026-06-23) + `flags_snapshot_test.exs` asserting Flags ≡ the feed's 48 real nations exactly
  (coverage + no-stale) and every placeholder → ⚽. Mutation-verified. Regen via `curl|jq` documented in the
  test moduledoc (the stand-in for the live-feed fetch CI can't do).
- **`predictex-dmh` CLOSED** (`f7c577d`) — async-safety review done; `fixture_live`/`leaderboard`/`my_predictions`
  now `async: true`. **Two root causes** (not the bead's single guess): (1) `Replay.Cache` singleton GenServer
  reads the Repo in its own process → `Sandbox.allow/3` in the replay setup; (2) `rounds.ordinal` unique-index
  **deadlock** (40P01) — `live_ids_test` inserted KO-ordinal-4 before group-ordinal-1 while others go ascending
  → lock cycle. Fixed by ascending order; the **suite-wide "create rounds ascending" invariant is documented in
  `DataCase.setup_sandbox`**. This was the real "intermittent flake" behind the `Postgrex disconnected` noise
  (that log line itself is **known-benign** sandbox teardown). Verified 0/20 full-suite runs.
- **ADR 0001 added** (`368e6d6`) — `docs/adr/0001-capture-worker-deployment-isolation.md` (first ADR; status
  **Deferred**). Records the curiosity-driven design: why multi-node is the wrong fix for deploy-mid-capture
  frame-loss, and the proportionate direction (one-image/two-role worker split + Postgres LISTEN/NOTIFY PubSub,
  with `4ya` capture durability as the complementary unplanned-restart fix). Trigger to revisit: post-28-Jun +
  recurring deploy friction. Cross-linked from `4ya`.

### ★ SHIPPED EARLIER (2026-06-23) — all deployed + verified live
- **Architecture review COMPLETE** (`improve-codebase-architecture`): **#4** prediction-intake boundary
  (`Predictions.parse_pick_rows/2`+`validate_pick_rows/1`, `47fc15c`), **#3** single ranking snapshot
  (`Standings.snapshot/0`, ~11 board loads/event→1, `277142c`), **#1** shared pure ranking core
  (`Predictex.Ranking` — `Standings`+`Leaderboard` both feed one fold; `4ea177f`). All pushed + deployed.
  Follow-up: **`predictex-0ft`** (P4) — memoize the base ranking in the snapshot so in-memory `project` stops re-ranking.
- **`predictex-ius` (v0.11.13) — weather-proof live capture.** `LiveScoreSync` keeps capturing while `is_live`
  (FIFA `MatchStatus 11`=weather suspension stays live), so a delayed match isn't cut at kickoff+210min;
  `clear_stuck_live` backstop → `@abandon_min`=360. Found via France v Iraq (a ~2h half-time weather break truncated
  capture at 74'). bd memory `fifa-matchstatus-11-suspended`.
- **`predictex-iy1` (v0.11.13) — FIFA-capture result fallback.** `ResultSync` settles a played GROUP fixture
  provisionally from the captured FIFA finished frame (`MatchStatus 0`) when openfootball lags;
  `Predictex.Results.FifaFallback`; plus an `Ingest` no-downgrade guard so a `:completed` fixture never reverts to
  `:scheduled`. VERIFY on the next openfootball lag (real-world). Spec/plan: `docs/superpowers/{specs,plans}/2026-06-23-iy1-*`.
- **`predictex-hco` WS1 (v0.11.14)** — see "NEXT" above.
- **`g8m` CLOSED** — no-dup invariant verified at partial bracket resolution (3 R32 teams resolved in place, 0 dups).
- **⚠️ France v Iraq settled manually 3-0** (admin override) — openfootball STILL has no result for it; if it never
  lands, the manual override stands (the fallback can't help — its capture predates the ius fix, so no finished frame).

### Knockout Game — design refs (Phase 1 deployed; Phase 2 deferred)
Spec/plan: `docs/superpowers/{specs/2026-06-22-knockout-game-native-predictions-design.md,plans/2026-06-22-knockout-game-phase1-foundation.md}`.
SDD ledger: `.superpowers/sdd/progress.md`. The write-auth round-membership guard lives in `save_round_predictions/4`
(member+admin saves route through `parse_pick_rows/2` since arch #4). Task-0 spike:
`docs/superpowers/research/2026-06-22-knockout-fifa-feed-spike.md` (squad↔scorer `IdPlayer` join confirmed 8/8;
picker deferred — squad rosters absent pre-match).

---

**Latest deployed tag `v0.11.12`** (deployed + verified 2026-06-21: Deploy success, `/health` 200, anon
`/` 200) — bundles **`kcx`** ("If your pick lands" projected leaderboard on `/fixtures/:id`: per-viewer
what-if on the member's OWN scoreline pick; pre-kickoff shows only the viewer's own row/headline, full
board after kickoff — anti-copy render gate; v1 scoreline-only w/ knockout caveat; unconditional, read-only)
**+ `i1s` adaptive replay pacing** (`Replay.tick_delay_ms/1`: 1400ms dwell on score-change frames, 250ms
rush through minute-only filler — was a flat 1s/frame that crawled). No migration (both additive).
Reviewed clean (kcx: code-reviewer, no material issues). Spec/plan:
`docs/superpowers/{specs/2026-06-21-kcx-pick-projection-design.md,plans/2026-06-21-kcx-pick-projection.md}`.
**Both CLOSED 2026-06-22** (eyeballed in prod: kcx pre-kickoff + live; i1s replay pace accepted).

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

> 🚫 **DEPLOY RULE (durable): never `git tag vX.Y.Z` mid-capture** — a container recreate drops
> in-progress frames. The 2026-06-21 Spain-match freeze is **lifted** (match over; v0.11.12 had landed
> ~16:52 BST before kickoff). Going forward, before any deploy check no match is live/capturing; plain
> `main` pushes are always safe (Quality job only, no recreate).

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

**▶ NEXT — start here next session:** see the **"⏵ Continue here"** block at the top — it's the current source
of truth. Headline: everything is deployed (`v0.11.16`); the **28 Jun knockout cutover** is the focus (verify
`hco` WS1 self-arms `32/32` + first-KO capture; verify Phase 1 native R32 entry renders). Backlog below.

**Recently CLOSED:** `2mh` (prediction writes broadcast `:fixtures_changed`, deployed v0.11.16 2026-06-24) ·
`4ez` (per-fixture breakdown + risky banner, deployed v0.11.15 2026-06-24) ·
`c9s` (flags golden-file snapshot, 2026-06-23) · `dmh` (async-safety / 2 root causes,
2026-06-23) · `g8m` (KO no-dup, 2026-06-23) · `ius`/`iy1` (weather capture + result fallback, v0.11.13) ·
`kcx`/`i1s`/`p4o` (2026-06-22). Specs/plans under `docs/superpowers/` if detail is needed.

1. **`predictex-hco` (P2, IN PROGRESS) — WS1 BUILT + DEPLOYED (v0.11.14), self-arming.** `Workers.KnockoutIds`
   (`*/10`) backfills KO `fifa_match_id` the moment FIFA publishes `rounds.json` KO matches (name-join + KO-only
   slot fallback). WS2/WS3 ✅; `g8m` closed. **Verify on 28 Jun:** `KO fifa_match_id: 32/32` then first-KO capture
   through ET/pens, `is_live` clears → close `hco`.

2. **Other backlog (`bd ready`):** `cij`/`i9k` (KO Phase 2), `bl8` (Live.Updater rescue), `l3n` (rfm capture
   polish), `uyf` (P4, knockout-ET goal filtering — gated on `hco`), `4ya` (P4, capture durability — see ADR
   0001), `3kv`/perf items. (`4ez` + `2mh` CLOSED + deployed this session; `c9s` + `dmh` CLOSED previously.)
   - **DEFERRED this session:** `0ft` (memoize ranking in snapshot) + `a4j` (cache `Standings.leaderboard/0`) —
     both premature per their own bead text at ~15-player scale; revisit triggers + safe-approach notes recorded
     on each bead (`bd show predictex-0ft` / `predictex-a4j`). `bd undefer <id>` to restore when a trigger fires.

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
- **499 tests** green (492 tests + 7 property laws). The 3 ConnCase live-test files now run `async: true`
  (`dmh`); when a test creates multiple rounds, insert them **ascending by `:ordinal`** (deadlock invariant,
  documented in `DataCase.setup_sandbox`). **The gate is `mix precommit`** (compile --warnings-as-errors,
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
- `Predictex.Ranking` — **pure** shared ranking core (zero Repo/Ecto, architecture #1): the fold both boards run
  (group by round ordinal, Round Bonus completeness, `Scoring.round_total/2`, total, sort). Each board feeds it
  already-joined `%{name, scored}` entries + the fixture universe; only their join differs.
- `Predictex.Leaderboard` — **pure** DB-free aggregator (drives `mix predictex.leaderboard`); the team-name-join
  adapter over `Predictex.Ranking` (`Standings` is the FK-join adapter — #1 collapsed the duplicated loop).
- `Predictex.Standings` — DB-backed leaderboard. **`snapshot/0`** is the single Gather edge (loads players+fixtures
  once into `%Standings.Snapshot{}`); pure **`rank/1`** + **`project/4`** run over it (no Repo); `leaderboard/0`/
  `knockout_leaderboard/0` are thin edges. `Buzz` runs entirely over a passed snapshot (architecture #3). Entries
  carry `bonus_by_round` + per-fixture `fixture_id` so the dashboard reconciles totals.
- `Predictex.Predictions` — the **prediction-intake boundary** (architecture #4): pure `parse_pick_rows/2` +
  `validate_pick_rows/1` turn raw form params into validated pick rows and own the booster-on-blank invariant;
  the member + admin forms and FIFA import all cross it. Persistence (`save_round_predictions/4` /
  `admin_save_round_predictions/3`) trusts validated rows; the latter enforces round-membership write-auth.
- `Predictex.Dashboard` — read model for `/predictions`: pure `build/4` + `for_player/2` edge;
  consumes `Standings` as the **single scoring authority** (does no scoring of its own).
- `PredictexWeb.Flags` — team name → flag emoji, keyed on real openfootball strings (⚽ fallback).
- `Predictex.Results.Ingest` — DB ingestion (`plan/1` pure, `commit/1` act). Fixture identity: KO by stable
  `source_num`, group by `external_ref` (`find_fixture/1`, g8m); changeset-update casts only parsed attrs so
  cohort `%`s survive. **No-downgrade guard (iy1):** a `:completed` fixture never reverts to `:scheduled` when a
  sync carries no result.
- `Predictex.Results.FifaFallback` — **pure** `settle_attrs/2` + `run/0` edge (iy1): settles a played GROUP
  fixture from the captured FIFA finished frame (`MatchStatus 0`) when openfootball lags. The bounded exception
  to the two-writer rule.
- **Background jobs (Oban):** `Workers.ResultSync` (`*/15`) runs `Ingest.sync_from_url/0` **then `FifaFallback.run/0`**
  (unconditionally, so the fallback fires even when openfootball is down); `Workers.CohortSync` (hourly) applies
  `Fifa.Cohort.plan/3`, overwriting `cohort_*_pct`; `Workers.LiveScoreSync` (`*/5`) is the capture producer;
  `Workers.KnockoutIds` (`*/10`, hco WS1) self-arms KO `fifa_match_id` backfill. Sync sources injectable for tests
  (`:result_sync_fun`, `:fifa_fallback_fun`, `:cohort_source_fun`, `:ko_ids_rounds_fun`).
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
- `docs/adr/0001-capture-worker-deployment-isolation.md` — **first ADR** (status Deferred): deploy-mid-capture
  isolation — why not multi-node, the one-image/two-role worker split + Postgres-PubSub direction, relation to `4ya`.
- `CONTEXT.md` (repo root) — **domain glossary** (created during the architecture review): pick row,
  prediction-intake boundary, ranking snapshot, buzz, scenario + core terms. The `improve-codebase-architecture`
  grilling loop reads + extends it.
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
