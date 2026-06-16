# FIFA cohort auto-sync — design spec

**Issue:** `predictex-7ux` · **Date:** 2026-06-16 · **Status:** approved (brainstorm), advisor-reviewed
**Spike:** `docs/superpowers/research/2026-06-16-xox-fifa-import-spike.md`

## Purpose

The risky bonus needs each fixture's **cohort percentages** — the share of players who predicted
home / draw / away. Today those are **admin-entered (`a02`)** and the bonus is **silently skipped
when unset**. The spike found FIFA publishes this data, server-fetchable and auth-free, at
`play.fifa.com/json/match_predictor/matchStats.json` (keyed by FIFA `matchId`). This automates
populating cohort %, removing the admin toil and the silent-skip gap.

## Decisions (brainstorm)

1. **FIFA is the data source** — we mirror FIFA; cohort sync **overwrites** `cohort_*_pct` every
   run. Admin entry (`a02`) becomes a rarely-needed manual stop-gap (overwritten next sync).
   openfootball stays the fixture + result source (`mt6`/`Ingest` untouched) — kept as the
   independence fallback.
2. **Map with a pure function** — no stored `fifa_match_id`, no re-sourcing fixtures from FIFA,
   no stateful backfill. The FIFA `matchId` → `Fixture` mapping is computed at sync time by a
   pure function, matching the codebase's spine (`Predictex.Fifa`, `Results.Openfootball` are
   pure; `Ingest.plan/1` pure, `commit/1` acts).
3. **Hourly cadence** — cohort drifts slowly and only matters before a match locks; hourly is
   fresh enough and cheap (not every-15-min like results).

## Architecture (Gather → Decide → Act, mirroring `Ingest`)

- **Decide (pure):** `Predictex.Fifa.Cohort.plan(rounds, match_stats, fixtures)` →
  `[%{fixture_id, cohort_home_pct, cohort_draw_pct, cohort_away_pct}]`. No DB, no network.
- **Act (edge):** `Predictex.Workers.CohortSync` — an Oban worker on the `mt6` substrate.
  `Req.get` `rounds.json` + `matchStats.json`, load `Tournament.list_fixtures/0`, call `plan/3`,
  then `Tournament.update_fixture/2` per planned row (reuses the existing changeset, which already
  validates `0..100`).

```
hourly cron -> CohortSync.perform
  rounds.json (matchId -> teams/date) + matchStats.json (matchId -> homeWin/draw/awayWin)
    -> Fifa.Cohort.plan(rounds, stats, fixtures)   [pure: join + orient]
    -> for each row: Tournament.update_fixture(fixture, cohort_attrs)
```

## The pure mapper — `Predictex.Fifa.Cohort`

### `plan(rounds, match_stats, fixtures) :: [cohort_update]`

For each FIFA match `m` (a `tournaments[]` entry from `rounds.json`, joined to its
`match_stats[matchId]` by `matchId`):

1. **Identity match.** Compute `key = {utc_date(m.date), MapSet.new([norm(m.homeSquadName),
   norm(m.awaySquadName)])}`. Find the fixture whose key equals it
   (`{utc_date(fixture.kickoff_at), MapSet.new([norm(fixture.team1), norm(fixture.team2)])}`).
   The **unordered team set** identifies the match; the **UTC date** disambiguates and guards.
2. **Orient by identity (load-bearing — neutral-venue matches let the two sources disagree on
   home/away):**
   - if `norm(m.homeSquadName) == norm(fixture.team1)` →
     `cohort_home_pct = stats.homeWin`, `cohort_away_pct = stats.awayWin`
   - else (FIFA's home is our `team2`) → **swap**:
     `cohort_home_pct = stats.awayWin`, `cohort_away_pct = stats.homeWin`
   - `cohort_draw_pct = stats.draw` (orientation-independent)
3. Emit `%{fixture_id: fixture.id, cohort_home_pct:, cohort_draw_pct:, cohort_away_pct:}`.

Unmatched FIFA matches (no fixture, or no `matchStats` entry) are **omitted**; the caller counts
them. Fixtures with no FIFA match are left untouched.

> **Why orientation matters:** `cohort_home_pct`/`cohort_away_pct` are home/away-specific scoring
> inputs. If FIFA lists `home=Iran, away=Spain` but our fixture is `team1=Spain, team2=Iran`, a
> set-only match would write Iran's win-share into Spain's slot — a contrarian predicting Spain
> would be scored against Iran's cohort. The orient step fixes this; the swap test must assert
> **values land on the correct team**.

### `norm(team_name) :: String.t()` (pure)

Downcase + trim + collapse whitespace, then apply a FIFA↔openfootball **alias table** for the
known divergences (e.g. `"IR Iran" → "iran"`, `"Korea Republic"`, `"Czechia"`,
`"Côte d'Ivoire"`, `"Congo DR"`, `"Cabo Verde"`, `"Curaçao"`, `"Bosnia and Herzegovina"`). This
is pure data; it overlaps `predictex-c9s` (team-name snapshot) — the alias table is the shared
artifact. An unmatched match (incomplete alias table) is the failure mode; see signalling below.

### `utc_date(datetime) :: Date.t()` (pure)

FIFA `date` is offset-bearing (`...+01:00`); fixture `kickoff_at` is UTC. Both are converted to a
UTC `Date` for the key (day-level guard — robust to minor kickoff-time differences between sources).

## Authority & interaction with existing sync

- Cohort sync **overwrites** `cohort_*_pct` (FIFA is the source). `Ingest`'s result re-sync already
  **excludes** `cohort_*_pct` from its `@replace_on_conflict` list, so the openfootball result sync
  and the FIFA cohort sync never fight over the column.
- `cohort_draw_pct` is populated for completeness but is **not read by scoring** (the risky bonus
  only reads `cohort_home_pct`/`cohort_away_pct`, for home/away-win predictions; draw predictions
  score 0 risky).

## Config / scheduling

- Add to the existing Oban `Cron` crontab (`config.exs`):
  `{"0 * * * *", Predictex.Workers.CohortSync}`.
- Worker: `use Oban.Worker, queue: :default, max_attempts: 3`. The FIFA source is injectable
  (`:cohort_sync_fun`, default a real `Req.get` of both files) so tests run network-free — same
  pattern as `:result_sync_fun`.

## Error handling

- Fetch failure / non-200 / bad JSON → worker returns `{:error, reason}` → Oban retry + backoff
  (`max_attempts: 3`), like `ResultSync`.
- Unmatched FIFA match → omitted, counted, logged. **Operator signal already exists:** the `a02`
  fixtures page renders **"cohort not set — risky bonus off"** for any fixture still missing
  cohort — that badge *is* the "a FIFA match didn't map" indicator (incomplete alias table or a
  fixture not yet synced). No new alerting.
- `matchStats.json` is group-stage only (72 matches) today; knockout cohort fills automatically
  once those rounds populate.

## Testing

- **Pure `plan/3` (no DB/network):**
  - exact match → correct fixture, correct `cohort_*_pct` values.
  - **orientation:** a fixture whose source orders teams **opposite** to FIFA → assert
    `cohort_home_pct` is the share for **our `team1`** (the swap landed values correctly).
  - alias match (`"IR Iran"` ↔ `"Iran"`) succeeds.
  - unmatched FIFA match → omitted (not in output).
  - draw → `cohort_draw_pct`, orientation-independent.
  - (Optional soft guard: `home+draw+away in 99..101` — log, don't fail; rounding can sum to 99.)
- **Worker (`Oban.Testing.perform_job`):** stubbed `:cohort_sync_fun` returns canned
  rounds+stats → assert cohort lands on a seeded fixture **and `Standings`/`Scoring` now awards the
  risky bonus** that was previously skipped. Failure stub → `{:error, _}`.
- **Cron registered:** assert `{"0 * * * *", CohortSync}` is in the Oban crontab.
- Full suite boots with the new worker (Oban Cron validates it at boot).

## Out of scope (YAGNI)

Storing `fifa_match_id`; re-sourcing fixtures/results from FIFA (deferred — openfootball stays
primary, FIFA-canonical fixtures is a separate future call); knockout name-matching for the
`xox` import (separate issue); new alerting; admin "cohort overridden by FIFA" UI.

## Open check (non-blocking)

Verify against prod whether FIFA's `homeSquadName` ever differs from openfootball's `team1` for
the same match. If they **never** disagree, the orient step degrades to an assert-and-log guard;
either way the spec keeps the explicit swap rather than assuming positional alignment.
