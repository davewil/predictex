# "If your pick lands" (kcx) — Implementation Plan

**Spec:** `docs/superpowers/specs/2026-06-21-kcx-pick-projection-design.md`
**Bead:** predictex-kcx
**Approach:** TDD, smallest vertical slices. Gate = `mix precommit` green per commit.

## Task 1 — `Predictions.get_player_fixture_prediction/2` (focused getter)

- **Test (`test/predictex/predictions_test.exs`):** returns the player's own `%Prediction{}`
  for the fixture; `nil` when that player has no pick; does **not** return another player's pick
  for the same fixture.
- **Impl (`lib/predictex/predictions.ex`):** `from p in Prediction, where: player_id and
  fixture_id` |> `Repo.one`. No preload needed (we only read `home_goals`/`away_goals`/stage
  flags from the fixture, not the prediction's player).

## Task 2 — `Buzz.pick_projection/4` (pure helper)

- **Test (`test/predictex/buzz_test.exs`):**
  - returns `%{rows: [...], viewer: ...}`; `rows` scored as if fixture finished `(h,a)`
    (cross-check a player total against `Standings.project/3`).
  - `viewer` row has correct `rank`/`prev_rank`/`delta` vs current standings.
  - viewer absent from current standings → `viewer.delta == nil`, rank present.
  - viewer not in projected board → `viewer == nil`.
- **Impl (`lib/predictex/buzz.ex`):** extract the per-row enrichment in `scenarios_with_deltas/3`
  into a shared private `enrich_rows(leaderboard, current_index)`; reuse it. `pick_projection/4`
  computes `current = rank_index(Standings.leaderboard())` once, projects once, enriches, then
  picks out the viewer row.

## Task 3 — `FixtureLive` assign + render

- **Test (`test/predictex_web/live/fixture_live_test.exs`):**
  - pre-kickoff + viewer has pick → card present, viewer's own row + delta shown; another
    player's name/scoreline **absent** from the card region (anti-copy).
  - post-kickoff (locked) + viewer has pick → full top-8 board, viewer row highlighted.
  - viewer has no pick → card absent.
  - fixture `:completed` → card absent.
  - knockout fixture → caveat line present.
- **Impl (`lib/predictex_web/live/fixture_live.ex`):**
  - `load_all`: compute `viewer_pick` (focused getter); set `@pick_projection` when
    `viewer_pick && fixture.status != :completed`, else `nil`. Same `recompute?` path as
    `@scenarios` already covers state flips.
  - `apply_frame` (replay): leave `@pick_projection` untouched (stays `nil`). Add an assertion
    or assign-nil for safety.
  - render: new `<section :if={@pick_projection}>` — headline always; top-8 board only
    `:if={@picks_visible?}`; caveat `:if={@knockout?}`. Reuse the `movement/1` + row markup
    from the "What if…" section.

## Task 4 — gate + commit

- `mix precommit` green (compile --warnings-as-errors, deps, format, credo --strict, test).
- Commit (do **not** push — user's call). Update bead + RESUME.

## Review

- After Task 3, request a focused code review (anti-copy correctness is the highest-risk part:
  confirm no other-player pick data reaches the pre-kickoff DOM).
