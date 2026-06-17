# Live Buzz Plan — Verified Corrections (read with every task brief)

The plan `2026-06-17-live-buzz.md` uses placeholder names for test factories and a
couple of context functions. These were verified against the real codebase on
2026-06-17. **Where the plan and this sheet disagree, this sheet governs.** Use these
exact names; do NOT invent new helpers or add functions that already exist.

## Test factories (CRITICAL)

- **Player:** `import Predictex.AccountsFixtures`, then `player_fixture(%{display_name: "Ana", email: "a@b.c"})`.
  NOT `Accounts.register_player_for_test`. Defaults come from `valid_player_attributes/0`; override `:display_name`/`:email` as needed.
- **Prediction on a LIVE / past-kickoff fixture:** use
  `Predictions.admin_upsert_prediction(%{player_id: p.id, fixture_id: fx.id, home_goals: 1, away_goals: 0})`.
  NOT `upsert_for_test`. **Why:** `Predictions.create_prediction/2` calls `ensure_open/2` and
  REJECTS predictions once kickoff has passed. Buzz/projection/fixture-live tests deliberately use
  past-kickoff (`status: :live`) fixtures, so they MUST use the admin path (it bypasses the lockout
  by design). Add `booster: true` to the attrs map when a test needs a booster.
- **Prediction on a fixture with `kickoff_at: nil` or future:** `Predictions.create_prediction/2`
  works (see `predict!/5` in `test/predictex/standings_test.exs` — copy that pattern).

## Existing functions to REUSE (do not re-create)

- **All picks for a fixture:** `Predictions.list_fixture_predictions/1` — already preloads `[:player]`,
  returns `%Prediction{}` structs with `.player.display_name`, `.home_goals`, `.away_goals`,
  `.booster`, `.first_scorer_side`. The plan's `Predictions.list_for_fixture/1` does NOT exist — use
  this instead. In `FixtureLive` render: `p.player.display_name`.
- **Lock check:** `Predictions.locked?(fixture, now)` exists (true once kickoff passed). ✓
- **Ranking:** `Standings.rank/2` and `Standings.leaderboard/0` exist. `Standings` already aliases
  `Repo`, `Predictex.Accounts.Player`, `Predictex.Tournament.Fixture` — `project/3` can use them directly.
- **Crosswalk:** `Predictex.Fifa.Crosswalk.match_key/3` exists. ✓
- **Tournament:** `create_round/1`, `create_fixture/1`, `get_fixture!/1`, `update_fixture/2`,
  `list_fixtures/0` exist. `list_live_fixtures/0` does NOT — add it in Task 9.

## Data shapes

- **Leaderboard / `rank/2` entry:** `%{player_id, name, fixtures_total, round_bonus_total, total,
  bonus_by_round, breakdown}`. `name` = `player.display_name`; `total` = points. Buzz's `rank_index`
  keying on `entry.player_id` / `entry.name` is correct.
- **Auth/viewer:** `socket.assigns.current_scope.player.id` (confirmed in `my_predictions_live.ex`,
  `import_live.ex`). Authenticated LiveViews wrap render in `<Layouts.app current_scope={@current_scope}>`.

## Routing

- `/fixtures/:id` (Task 8) goes inside the existing `live_session :require_authenticated_player`
  block (`router.ex`, the block that already holds `/predictions`, `/import`).
- `LeaderboardLive` is the PUBLIC route `live "/", LeaderboardLive, :index` under `pipe_through :browser`
  (no auth). The Task 9 "Live now" card lives there.

## Verified non-issues (do NOT "fix" these; they are intended)

- **`status: :live` in test setups is valid.** The `Fixture` status enum is
  `[:scheduled, :live, :completed]`, so `create_fixture(%{... status: :live ...})` succeeds and
  Task 4's `get_fixture!(fx.id).status == :live` assertion holds. NOTE the distinction: tests may
  set `status: :live` directly, but **production `LiveScoreSync` must still write only `is_live` +
  `live_*`, never `status`** (the two-writer constraint is about production writes, not test setup).
  `rank/2` scores only `:completed` fixtures, so a `:live` fixture scores 0 in the real leaderboard —
  exactly what the projection tests rely on.
- **"Live now" card (Task 9) is not real-time.** It reads `list_live_fixtures/0` at mount with no
  PubSub subscription, so it refreshes on navigation, not on each score tick. Intended simplification —
  only the `/fixtures/:id` drill-down (Task 8) is live via `"fixture:#{id}"`. Do not flag as a miss.
- **Round bonus in `project/3` only changes once a round is complete.** `rank/2` gates round bonus on
  `meta.complete?`, so for a single mid-round live match the projection reflects fixture points but no
  round-bonus delta. Correct behaviour (the spec's "round bonus honoured for free" overstates the live
  case). Do not flag.

## FixtureCard (Task 7)

- Component is `def fixture_card(assigns)` in `predictex_web/components/predictex_components.ex`.
  It takes `attr :fx, :map, required: true` (so `@fx.fixture.*`), `attr :stage`, `attr :fifa_url`.
  Add `attr :live_buzz?, :boolean, default: false` and render the LIVE badge from
  `@fx.fixture.is_live` + `@fx.fixture.live_*`. The card header is around line 153 (kickoff line).
