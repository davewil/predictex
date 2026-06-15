# Admin Console — design spec

**Issue:** `predictex-a02` · **Date:** 2026-06-15 · **Status:** approved (brainstorm), advisor-reviewed

## Purpose

The admin-only console at `/admin` is the operational cockpit for the league. Its
headline job — the thing that makes the game *playable* — is **admin entry of
predictions on behalf of players**: members make their picks on the official FIFA
Match Predictor and submit screenshots, and the admin transcribes them here. The
read-only `/predictions` dashboard (`predictex-79q`, done) only *displays* those picks;
entry lives here.

Alongside prediction entry, the console gathers the other admin operations that today
only exist as release-function CLI calls or are unbuilt: triggering a results sync,
overriding a result by hand, entering per-fixture FIFA cohort percentages (which drive
the "risky" scoring bonus), and promoting players to admin.

## Scope

In scope (full console — five capabilities, one spec):

1. **Predictions entry** on behalf of players — two lenses over the same data:
   - **By player** (primary): pick a player + round, fill that player's whole round from
     their screenshot batch.
   - **By fixture** (audit): pick a fixture, see every player's pick, spot who's missing.
2. **Fixtures**: "Sync from feed" button; per-fixture result override; per-fixture cohort %.
3. **Players**: list players, promote to admin.

Out of scope (explicit YAGNI):
- Prediction delete, player delete.
- Audit log of admin edits.
- Bulk CSV / automated import — that is `predictex-xox`.
- A standalone "recompute" action — `Standings.leaderboard/0` recomputes on read, so a
  re-render *is* the recompute.

## Key decisions (brainstorm)

1. **Admin entry bypasses the kickoff lockout.** The screenshot is proof the player
   picked in time; the lockout exists to stop players self-serving late, not to stop
   admin backfill. A solo admin must be able to enter round-1 picks on day 3. New domain
   function; the player-facing `create_prediction/2` (which *does* lock) stays untouched.
2. **Full console**, all five capabilities in one slice.
3. **Both lenses** (by player / by fixture) over the same prediction data.
4. **Separate sub-route LiveViews** under one `:require_admin` live_session — focused,
   independently testable files, matching the project's "small well-bounded units" and
   LiveView-discipline conventions.

## Domain layer (new / changed)

The console is a thin shell over context functions. New domain code is deliberately small
and all of it carries tests.

### `Predictex.Predictions`

- **`admin_save_round_predictions(player_id, round_id, rows)`** — the By-player "Save all"
  path. Runs in a single `Repo.transaction`:
  1. Clear the booster flag on **all** existing predictions for `{player_id, round_id}`
     (`UPDATE ... SET booster = false`).
  2. Upsert each non-blank row (see partial-row semantics below).

  Clearing booster *first* is load-bearing: the `one_booster_per_player_round` partial
  unique index is **not deferrable**, so moving a booster from fixture A to fixture B by
  iterating per row can transiently leave two `booster = true` rows in the round and the
  DB rejects the valid edit. Clearing up front removes the transient collision. Returns
  `{:ok, summary}` (per-row results: `:inserted` / `:updated` / `:skipped` / `{:error, cs}`)
  or rolls back on a non-recoverable error.

- **`admin_upsert_prediction(attrs)`** — the By-fixture single-row path. Insert-or-update
  keyed on `{player_id, fixture_id}`, **no `ensure_open` check** (Decision 1). Sets
  `round_id` from the fixture (keeps the denormalization the booster index relies on).
  Transactional: if the incoming row sets `booster: true`, clear any other booster for
  `{player_id, round_id}` first, then upsert. The booster constraint remains the backstop
  and surfaces as `{:error, changeset}` ("booster already used in this round").

- **`list_fixture_predictions(fixture_id)`** — all players' picks for one fixture
  (drives the By-fixture lens), preloaded for display.

### `Predictex.Accounts`

- **`set_player_admin(player_id, is_admin)`** — id-based, tuple-returning
  (`{:ok, player}` / `{:error, changeset}`) sibling to the existing email-based
  `promote_admin/1`, so the Players button has a UI-friendly path.

### Reused as-is

`Tournament.update_fixture/2` (result override + cohort %), `Tournament.list_rounds/0`,
`Tournament.list_fixtures/0`, `Results.Ingest.sync_from_url/0` /
`Results.Ingest.sync_from_file/1`, `Accounts.list_players/0`, `Standings.leaderboard/0`.

## Data contract — prediction fields (verified against `Scoring.score/3`)

`Scoring.score/3` reads these prediction fields (scoring.ex:55–158). The entry grid MUST
capture exactly these — nothing less (phantom data that never scores), nothing more:

| Field | Type | Required? | Scoring use |
|-------|------|-----------|-------------|
| `home_goals` | integer ≥ 0 | **yes** | exact score, correct goals, result |
| `away_goals` | integer ≥ 0 | **yes** | exact score, correct goals, result |
| `first_scorer_side` | `:home` / `:away` | no | first-team component (`pred.side == fixture.side`) |
| `first_scorer_player` | string | no | first-player component (normalized match, skipped on own-goal) |
| `booster` | boolean | no (≤1 per round) | doubles `base_total` on that fixture |

> The single free-text "1st scorer" box in early sketches was wrong — `first_scorer_side`
> and `first_scorer_player` are **two separate fields** and the team component keys on the
> *side*. The grid captures both: a side selector (home / away / none) and a player-name
> text input, both optional.

### Partial-row semantics (By-player grid)

The grid is routinely sparse (admin has only some screenshots; a player skipped matches).

- **Blank row** (both `home_goals` and `away_goals` empty) → skipped, no upsert.
- **Complete row** (both goals present) → upsert. First-scorer fields optional.
- **Half-filled row** (exactly one goal present) → `{:error, changeset}` surfaced on that
  row (`validate_required` on both goals).
- **Booster on a blank row** → error ("can't boost a fixture with no scoreline"). The
  booster radio may only target a row that has a scoreline.

## Routes & LiveViews (Decision 4)

```elixir
scope "/", PredictexWeb do
  pipe_through [:browser, :require_authenticated_player]

  live_session :require_admin,
    on_mount: [{PredictexWeb.PlayerAuth, :require_authenticated},
               {PredictexWeb.PlayerAuth, :require_admin}] do
    live "/admin",             AdminLive,            :index   # nav landing + summary
    live "/admin/predictions", AdminPredictionsLive, :index   # ?view=player|fixture
    live "/admin/fixtures",    AdminFixturesLive,    :index
    live "/admin/players",     AdminPlayersLive,     :index
  end
end
```

Auth note (verified, player_auth.ex:233): `:require_admin` calls `mount_current_scope`
itself and guards `current_scope && current_scope.player && is_admin`, so a nil scope
**redirects to `/`, it does not raise** — safe standalone. The chain above adds
`:require_authenticated` first so a logged-out user gets a *login* redirect rather than an
"admin only" flash, and the `:require_authenticated_player` plug guards the dead render —
mirroring the existing authenticated block.

A shared `admin_nav/1` function component renders the section bar. An **"Admin"** link is
added to the app nav, shown only when `current_scope.player.is_admin`.

## Section detail

### Predictions (`/admin/predictions`)

- **By player** (`?view=player`, default): select player + round → grid, one row per
  fixture in that round (home/away goal inputs, first-scorer side select + player text).
  The booster is a **single radio across the whole grid** ("none" + one per fixture), so
  the one-per-round rule is structurally unrepresentable in the UI; the DB constraint is
  the backstop. "Save all" → `admin_save_round_predictions/3`, per-row results reported.
- **By fixture** (`?view=fixture`): select fixture → every player's pick in rows, empty
  picks flagged. Save → `admin_upsert_prediction/1` per edited row.
- Both lenses pre-load existing predictions keyed by `fixture_id` so re-entry shows
  current values (edit, not just create).

### Fixtures (`/admin/fixtures`)

- Fixtures listed grouped by round.
- **"Sync from feed"** button → `Results.Ingest.sync_from_url/0` via
  `Phoenix.LiveView.start_async` (network call off the render path, isolated to the LV
  process, result reported via `handle_async` as a flash).
- Per fixture: edit result (`home_goals`, `away_goals`, `first_scorer_side`,
  `first_scorer_player`, `first_goal_owngoal`, `status`) and cohort %
  (`cohort_home_pct`, `cohort_draw_pct`, `cohort_away_pct`) via `update_fixture/2`.
- **Unset cohort renders explicitly** — "cohort not set — risky bonus off" — never a
  silent default (per the RESUME warning).

### Players (`/admin/players`)

- `list_players/0` table: email, display name, admin?. Promote button →
  `set_player_admin/2`. No delete.

## LiveView discipline

Every section consumes validated context returns and pattern-matches tuples — **no
`try`/`raise`/`panic` in the LiveViews** (project rule). Forms via `to_form`. Save paths
surface `{:error, changeset}` as inline form errors; the booster conflict surfaces as
"booster already used in this round" on the offending row.

## Testing

Following the project's fixture-honesty and full-flow rules:

- **Context unit tests**
  - `admin_upsert_prediction/1`: insert; overwrite existing; **succeeds after kickoff**
    (the bypass); booster set; **booster *move* A→B** (the case the transactional clear
    exists for); booster-on-blank rejected.
  - `admin_save_round_predictions/3`: sparse grid (blank skipped, half-filled errors,
    complete upserts); booster radio move within one save.
  - `set_player_admin/2`.
- **LiveView flow tests** (page A → click → page B, fixtures built through production code
  paths only)
  - `:require_admin` gate: non-admin redirected; logged-out redirected to login.
  - By-player entry saves → value appears on `/predictions`.
  - By-fixture audit lens.
  - Fixture result override → reflected in `Standings`.
  - Cohort entry; unset-cohort visible state.
  - Sync button drives **`sync_from_file/1` or a stubbed source — never a live network
    fetch** (fixture honesty + non-flaky).
  - Promote player.

## Implementation sequencing note (for writing-plans)

Because this is a deliberately large slice, order the plan so **predictions-entry lands
and is testable first** (it is the playability unlock), then Fixtures, then Players — so a
mid-implementation stop still leaves something shippable.
