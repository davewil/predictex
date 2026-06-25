# "As it stands" projected R32 bracket — design

- **Bead:** `predictex-7qu`
- **Date:** 2026-06-25
- **Status:** design — revised after the thirds spike (awaiting user review → `writing-plans`)
- **Spike:** `docs/superpowers/research/2026-06-25-bracket-thirds-table-spike.md` (decided against the
  495-row FIFA table; see Decision #2)

## Summary

A public, read-only `/bracket` page that shows the **projected Round of 32 "as it stands"** —
BBC-style — computed live from the actual group-stage results. As group results land the page
updates over PubSub, showing who would play who in the R32 given the current group tables.

This is **informational/engagement**, not a prediction surface: it uses *actual* match results
(the same data the leaderboard scores against), never anyone's predictions. It is public like the
leaderboard; there is no copy-risk because it reveals no picks.

## Scope

- **In scope:** the 12 group tables (A–L) "as it stands", and the projected **Round of 32**
  matchups derived from them. Winner/runner-up slots resolve to exact teams; third-placed slots show
  the candidate set + a ranked best-thirds panel, and become exact named teams automatically once the
  group stage ends (via the existing ingest — see Decision #2 and the spike).
- **Out of scope (R32 only):** R16/QF/SF/Final projections. Those depend on *knockout* results,
  which cannot be projected from group standings. The bracket tree beyond R32 is not shown.
- **Out of scope:** any tie-in to the native KO prediction entry (`predictex-5q6`) — separate
  surface, separate page.

### Shelf-life

The projection matters from now until the group stage ends (~28 Jun 2026). Once the last group
match settles, openfootball + `Workers.KnockoutIds` resolve the **actual** R32 teams in place, at
which point the page shows the real bracket (projection == actual). The feature degrades
gracefully into a correct, if no-longer-"projected", bracket view after that.

## Decisions (locked during brainstorming)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Primary output = **projected R32 bracket** (group tables shown as supporting detail) | What "as it stands knockout" means; matches BBC. |
| 2 | **Candidate-set rendering** for third-slots (NOT the 495-row FIFA table), with exact named thirds arriving automatically from the existing ingest at group-stage end | The spike proved the candidate sets admit multiple valid matchings for *all* 495 combinations (so the table is mandatory for exact mid-stage projection), AND the table is hand-source-only and not CI-verifiable (a wrong-but-valid row passes any check we can run). For a ~3-day shelf-life that trade is poor. openfootball + `Workers.KnockoutIds` apply FIFA's table for us and resolve the real R32 teams ~28 Jun — so exact thirds appear at the moment they're real, for zero fragile data. A greedy stand-in is explicitly rejected (it can put one team in two matches). |
| 3 | New **public** page `/bracket`, linked in nav | Mirrors BBC; no auth, no copy-risk. Clean separation from prediction surfaces. |
| 4 | **R32 only** | Deeper rounds need KO results, not group standings. |
| 5 | **Live-updating** via the existing `:fixtures_changed` PubSub | Infra already exists (`Tournament.subscribe_changes/0`); near-zero cost, big payoff. |
| 6 | Pragmatic group tiebreakers: **Pts → GD → GF → "provisionally level"** | Head-to-head / fair-play / drawing-of-lots are rarely decisive and costly; a 15-person league tolerates an explicit "provisionally level" marker. The marker is **loudest at the 8th/9th-best-third cutoff**, where a tie flips in/out of the bracket, not just seeding. |
| 7 | The bracket **wiring is parsed from data, not hardcoded** | FIFA's `rounds.json` already stamped each R32 fixture with its feeder slot (`1C`, `2F`, `3A/B/C/D/F`, or an already-resolved real team name). |

## Architecture (pure cores, effects at edges)

Follows the established `Ranking`/`Standings` grain: pure DB-free computation, a thin Gather edge,
a LiveView at the boundary.

```
Group + R32 fixtures ──(Gather edge)──▶ GroupTables (pure) ──▶ Bracket.Thirds (pure) ──▶ Bracket (pure)
                                                                                              │
                                                              BracketLive (/bracket, public) ◀┘
                                                              subscribes :fixtures_changed
```

### `Predictex.GroupTables` — pure

DB-free. Input: the group-stage fixture universe (`team1`, `team2`, `group`, `home_goals`,
`away_goals`, `status`). Output: for each group letter, a ranked list of rows:

```
%GroupTables.Row{
  team, played, won, drawn, lost, gf, ga, gd, points,
  rank,                # 1..N within the group, after tiebreakers
  provisional_tie?     # true when this row is level with an adjacent row on Pts+GD+GF
}
```

- Only `:completed` fixtures contribute to W/D/L/points (a live or scheduled fixture is not yet a
  result). Goals come from `home_goals`/`away_goals` (own goals already reflected in the score).
- Tiebreakers: Pts → GD → GF, then a **stable** order (alphabetical by team) with `provisional_tie?`
  set so the UI can flag it. Never raises on partial data (a group mid-stage ranks what it has).

### `Predictex.Bracket.Thirds` — pure

Owns the **best-8-of-12 third-placed** ranking (no assignment table — see Decision #2).

- `ranked/1` — across all 12 groups, take each group's 3rd-placed row, rank them by Pts → GD → GF
  (same tiebreak), return the ordered list with a **cutoff at 8** and `provisional_cutoff_tie?` set
  when rows 8 and 9 are level (the decisive boundary — a tie *there* flips in/out of the bracket,
  not just seeding). This drives the "Best thirds so far (8 of 12 qualify)" panel.

### `Predictex.Bracket` — pure, **total**

Resolves each R32 fixture's two slots into something always renderable. The placeholder parser is an
**anti-corruption boundary**: every input maps cleanly, never raises.

`resolve_slot(placeholder, tables, thirds) ::`
- `"1C"` → `{:exact, winner_of("C")}` (rank 1 of group C, or `{:tbd, "Winner C"}` if C has no rank-1 yet)
- `"2F"` → `{:exact, runner_up_of("F")}` (rank 2, or `{:tbd, "Runners-up F"}`)
- `"3A/B/C/D/F"` → `{:candidate_set, ["A","B","C","D","F"]}` — honest uncertainty (the candidate
  sets can't pin a single team; see the spike). The "Best thirds so far" panel beside the bracket
  shows which of these are currently qualifying.
- a real team name (`"Germany"`) → `{:resolved, "Germany"}` — openfootball/`Workers.KnockoutIds`
  already settled this slot (the **exact-thirds-at-28-Jun path**: once the group stage ends, FIFA's
  own table is applied upstream and the real team lands here, so projection == actual with no table
  on our side)
- **anything unexpected** → `{:tbd, placeholder}` (render the raw label; never crash)

`build/2` returns the ordered R32 match list (each: home slot, away slot, FIFA match number /
kickoff if known) plus the group tables and the best-thirds panel data.

### Gather edge

A thin function (in `Tournament` or a small `Bracket.Source`) loading the group-stage fixtures and
the R32 fixtures in one place, then handing them to the pure core. No new schema. **No migration.**

### `PredictexWeb.BracketLive` — public `/bracket`

- Route added to the **public** (unauthenticated) scope, like `LeaderboardLive`.
- `mount` loads via the Gather edge; `connected?` → `Tournament.subscribe_changes()`.
- `handle_info(:fixtures_changed, ...)` re-pulls (mirrors `MyPredictionsLive`).
- Renders: the **R32 match list** (exact teams with flags via `PredictexWeb.Flags`; `3rd · {set}` for
  unresolved third-slots; `Winner C` / `Runners-up F` for not-yet-ranked slots), and a **"Best thirds
  so far (8 of 12 qualify)"** panel with the cutoff line + provisional-tie warning, and the **12 group
  tables** (top-2 highlighted, 3rd marked). Nav gains a "Bracket" link.

## Verification

No fragile data artifacts — the spike removed the only one (the 495-row table). Correctness rests on
the pure cores being exhaustively tested and the parser being **total**:

- The placeholder parser is a total anti-corruption function: every input (`1C` / `2F` / `3X/Y/Z` /
  a real team name / anything unexpected) maps to a renderable value, never raises.
- `GroupTables` and `Thirds.ranked/1` are pure and fully unit/property-tested (see Testing).
- The "exact thirds at 28 Jun" path needs no verification on our side — it's the existing,
  already-deployed openfootball/`Workers.KnockoutIds` ingest resolving the real team into the slot
  (the `{:resolved, name}` branch), which is independently covered by the ingest's own tests.

## Testing

- `GroupTables`: unit + property tests over crafted 12-group universes — full results, partial
  results (mid-stage), exact ties (provisional marker), own-goal scorelines, a group with 0 played.
- `Bracket.Thirds`: `ranked/1` cutoff at 8 + the 8/9 provisional-tie flag; early-stage path (fewer
  than 8 groups have a ranked third yet).
- `Bracket`: `resolve_slot/3` totality (every placeholder shape incl. garbage → renders), the four
  branches (exact winner/runner-up · candidate-set third · resolved-real-name · tbd); full `build/2`
  over a seeded universe, including the resolved-real-name branch (the 28-Jun path).
- `BracketLive`: public mount (no auth), renders projected matches + tables + thirds panel; live
  re-pull on `:fixtures_changed` (settle a group fixture → projection updates without remount).
- Gate: `mix precommit` (compile/format/credo/test) green; new code fully covered.

## Open questions for the plan

- Exact module home for the Gather edge (`Tournament` vs a dedicated `Bracket.Source`) — decide in
  the plan against existing query patterns.
- Whether to show kickoff/venue per projected match (data is on the R32 fixture) or keep it to the
  matchup — lean matchup-only for v1.

## Non-goals / YAGNI

- No R16+ projection. No prediction tie-in. No persistence/caching (recomputed per load + on PubSub;
  fine at this scale, same posture as the leaderboard). No head-to-head / fair-play tiebreakers in v1.
