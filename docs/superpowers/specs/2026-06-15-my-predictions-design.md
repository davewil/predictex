# My Predictions dashboard — design spec

**Issue:** `predictex-79q` · **Date:** 2026-06-15 · **Status:** approved (brainstorm)

## Purpose

A member's personal, **read-only** dashboard. Members make their predictions on the
official FIFA Match Predictor — *not* in this app — so this page exists to stop them
juggling two sites: it shows **your own imported picks, how they're scoring as results
land, and your league position**, in one place.

Predictions arrive in predictex by **auto-import** (the FIFA bookmarklet/scrape — issue
`predictex-xox`) or by **admin manual entry** from submitted screenshots (the Admin
LiveView — issue `predictex-a02`). Neither is built yet, so on day one this page will show
empty/"no pick imported" states until one of them feeds data. That is an accepted,
conscious sequencing choice (confirmed with the product owner).

This page does **no** prediction entry of any kind.

## Scope

In scope:
- Read-only personal dashboard at `/predictions`, authenticated members only.
- Per round (tabbed): each fixture with the member's predicted scoreline, booster marker,
  and — for knockout rounds — first-team / first-player picks.
- Per completed fixture: the actual result and the points that pick earned.
- Lock state (kickoff passed) and a clear "no pick imported yet" state.
- Header showing the member's rank and total (with fixtures/bonus split), reconciled
  exactly with the public leaderboard.
- An outbound "Make / update picks on FIFA" link.
- Redirect logged-in members to `/predictions` after login.

Out of scope (other issues):
- Any prediction entry — manual entry is admin-only and lives in `a02`; auto-import is `xox`.
- The FIFA scrape/bookmarklet itself (`xox`).

## Architecture

Follows the repo's Gather → Decide → Act / anti-corruption pattern: a read-model context
produces a fully-shaped, validated view so the LiveView only renders (pipes, no
`try`/`raise`, no branching on raw shapes). **`Predictex.Standings` stays the single
scoring authority** — the dashboard consumes its numbers rather than re-scoring, so the
header total can never disagree with the leaderboard rank.

### `Predictex.Standings` (enrich — additive, backward-compatible)

`score_player/3` currently returns `%{player_id, name, fixtures_total, round_bonus_total,
total, breakdown}` where `breakdown` is a list of `%{ordinal, result}`. Add, without
removing or renaming anything (existing `standings_test` asserts only
`fixtures_total`/`round_bonus_total`/`total`, and `LeaderboardLive` reads only
`name`/`fixtures_total`/`round_bonus_total`/`total`):

- `breakdown` entries gain `:fixture_id` → `%{ordinal, fixture_id, result}`.
- A new `:bonus_by_round` field → `%{ordinal => round_bonus_points}` (refactor the existing
  `round_bonus_total/2` to build a per-round map and sum it, so the per-round figure and
  the total come from one computation — no drift).

### `Predictex.Dashboard` (new read model)

- `for_player(player, now \\ DateTime.utc_now())` *(I/O edge)* — gathers:
  - rounds ordered by ordinal, each with its fixtures (ordered by kickoff then id);
  - the player's predictions, indexed by `fixture_id`;
  - the player's entry from `Standings.leaderboard/0`, plus their 1-based rank and the
    total player count.
  Then calls the pure `build/4` and returns its result.

- `build(rounds_with_fixtures, predictions_by_fixture, standings_entry, now)` *(pure,
  DB-free, unit-testable like `Standings.rank/2`)* → returns:

  ```elixir
  %{
    rank: 9, of: 14,
    total: 45, fixtures_total: 25, round_bonus_total: 20,
    rounds: [
      %{
        round: %Round{},
        active?: true,                # the default-selected tab
        round_bonus: 20,              # from standings_entry.bonus_by_round[ordinal]
        fixtures: [
          %{
            fixture: %Fixture{},
            prediction: %Prediction{} | nil,
            status: :scheduled | :live | :completed,
            locked?: true | false,    # Predictions.locked?/2
            points: 25 | nil,         # from standings_entry breakdown by fixture_id; nil unless completed+predicted
            exact?: true | false,     # predicted scoreline == actual (presentation flourish)
            booster?: true | false
          }
        ]
      }
    ]
  }
  ```

  `build` performs **no scoring arithmetic** — `points`/`round_bonus`/`total`/`rank` are all
  read from `standings_entry`. It only joins, computes lock state via `Predictions.locked?/2`,
  derives the boolean `exact?`/`booster?` display flags, and decides the active round.

- **Active round rule:** the lowest-ordinal round that is not fully completed; if every
  round is complete, the highest ordinal. Pure, defined in `build`.

## Web

`PredictexWeb.MyPredictionsLive`, route `live "/predictions", MyPredictionsLive, :index`
inside the existing `:require_authenticated_player` `live_session` (logged-out users
already redirect to `/players/log-in` via `PlayerAuth`). Mount calls
`Dashboard.for_player(current_scope.player)` and assigns the view model plus the
default-active round ordinal. Round tab switching is a `phx-click="select_round"` handler
that just changes which round's `:fixtures` are shown (all data is already loaded; no
re-query needed).

Rendering mirrors the approved mockup:
- Pitch-green hero with rank ("9th of 14") and total, plus a small "X fixtures · Y bonus"
  split (same three numbers as `LeaderboardLive`).
- Round tabs; locked/not-yet-open rounds visually de-emphasised.
- Page-level empty state when no rounds/schedule are loaded yet (mirror `LeaderboardLive`'s
  "No players yet" card) — distinct from the per-fixture "no pick imported" state.
- Per fixture: flag + team names, predicted scoreline, and either the actual result +
  points badge + ⚡ booster marker (completed), "Locked — awaiting result" (locked, not
  completed), or "⚠ No pick imported yet" (no prediction).
- Knockout rounds additionally show the first-team / first-player picks (rendered
  conditionally on `round.stage == :knockout`).
- "Make / update picks on FIFA →" link.
- Cross-nav between "My Predictions" and the public "Leaderboard".

Styling uses the app's existing daisyUI/Tailwind classes (as in `LeaderboardLive`) with the
World Cup theme (pitch-green hero, flags). The dashboard reuses `Layouts.app`.

### Flags

`PredictexWeb.Flags.flag/1` (pure) maps a team name → flag emoji. **Keyed on the exact
openfootball 2026 team strings** the feed actually produces
(`https://raw.githubusercontent.com/openfootball/worldcup.json/master/2026/worldcup.json`,
via `Predictex.Results.Ingest`) — verified against the live feed during implementation, not
guessed. Graceful fallback to ⚽ for any unmapped string (e.g. playoff-winner placeholders),
so an unknown team never breaks the page.

**On verification (be honest about what's testable):** CI cannot hit the live openfootball
feed, and a test that iterates the same nation list used to build the map only proves the map
contains its own keys — it is *not* data-contract verification. So: during implementation, do
a **one-time fetch-and-diff** of the live feed's team strings against the map keys, and log
which names fall back to ⚽ (a miss is cosmetic, caught by the fallback). For a genuine
regression test, commit a **snapshot of the feed's team-name list** as a fixture and test the
map against that snapshot. The unit test for `flag/1` itself just asserts a few known nations
→ real flags and unknown → ⚽.

### FIFA link config

`config :predictex, :fifa_predictor_url, "https://play.fifa.com/match-predictor/match"`
(tracking query string dropped — `intcmp` is a campaign param, not session data), overridable
via a `FIFA_PREDICTOR_URL` env var in `runtime.exs`. The button renders only when a URL is
configured.

### Post-login landing

Change `PlayerAuth.signed_in_path/1` so members land on `/predictions`. **Collapse it to a
single clause: `def signed_in_path(_), do: ~p"/predictions"`** — this is load-bearing.
Trace the path: `log_in_player` calls `signed_in_path(conn)` *after* session creation but
never assigns `current_scope`, so on a fresh login `current_scope.player` is `nil` and
execution falls through to the `_` clause (which is why the login tests currently assert
`/`). `registration.ex` passes a `%Phoenix.LiveView.Socket{}`, which never matches the
`%Plug.Conn{}` typed clause either — so both flows already hit `_`. Changing only the typed
`%Player{}` clause would leave the redirect on `/` and break the updated tests; changing the
`_` clause is the actual fix.

Update the affected auth tests in the same pass: the post-login redirect assertions in
`registration_test`, `login_test`, `confirmation_test`, and the `create` paths of
`player_session_controller_test` (→ `/predictions`). **Leave unchanged:** log-out → `/`
assertions (logout redirects to `~p"/"` explicitly, not via `signed_in_path`), and the
`response =~ "/players/settings"` assertions (those check the logged-in nav link in the body,
not the redirect target — still green as long as the nav links to settings).

## Testing

Build all test data through real production paths (test-fixture-honesty rule): players via
`player_fixture` (registration), fixtures via `Tournament.create_fixture`, predictions via
`Predictions.create_prediction`. No hand-set fields the app never writes.

- **`Dashboard.build/4` (pure, no DB):** exact-score fixture, outcome-only, missing pick,
  locked-but-not-completed, booster marker, knockout first-team/player, active-round
  selection (mid-tournament and all-complete cases), and that `total`/`points`/`rank` are
  taken verbatim from the supplied `standings_entry` (no recomputation).
- **`Dashboard.for_player/2` (DB):** end-to-end shape for a player with a mix of
  completed/locked/open/un-predicted fixtures across two rounds; rank reflects standing.
- **`Standings` enrichment:** `breakdown` entries carry `fixture_id`; `bonus_by_round` sums
  to `round_bonus_total`; existing assertions still pass.
- **`Flags.flag/1`:** known nations → real flags; unknown → ⚽.
- **`MyPredictionsLive`:** authenticated member sees their picks, points, rank, lock state,
  and "no pick imported" warning; logged-out redirects to `/players/log-in`; a member sees
  *their own* picks, not another player's (load two players, assert isolation); FIFA link
  present when configured.
- **Auth redirect:** post-login lands on `/predictions`.

Gates: `mix test`, `mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix deps.unlock --check-unused` (run via `mise exec -- mix …`).

## Issue hygiene

- Update `predictex-79q` description to "read-only personal dashboard" (drop the
  scoreline-entry / booster-toggle wording — entry is not here).
- Add a note to `predictex-a02` that admin manual entry of predictions *on behalf of
  players* (from submitted screenshots) lives there.

## Risks / deferred

- **Empty until fed:** dashboard shows "no pick imported" for everyone until `a02` or `xox`
  lands. Accepted.
- **Flag coverage:** WC2026 qualification may still contain placeholder entries; these fall
  back to ⚽ by design.
- **FIFA URL longevity:** the play.fifa.com path may change; it's config, not hardcoded.
- **Rank ties:** rank is the 1-based index into the sorted standings, so two players on equal
  points get distinct ranks (9th/10th), not joint-9th. A conscious, acceptable simplification
  for a ~15-person friends' league.
