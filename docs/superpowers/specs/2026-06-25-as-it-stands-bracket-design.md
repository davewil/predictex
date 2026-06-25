# "As it stands" projected R32 bracket — design

- **Bead:** `predictex-7qu`
- **Date:** 2026-06-25
- **Status:** design (awaiting user review → `writing-plans`)

## Summary

A public, read-only `/bracket` page that shows the **projected Round of 32 "as it stands"** —
BBC-style — computed live from the actual group-stage results. As group results land the page
updates over PubSub, showing who would play who in the R32 given the current group tables.

This is **informational/engagement**, not a prediction surface: it uses *actual* match results
(the same data the leaderboard scores against), never anyone's predictions. It is public like the
leaderboard; there is no copy-risk because it reveals no picks.

## Scope

- **In scope:** the 12 group tables (A–L) "as it stands", and the projected **Round of 32**
  matchups derived from them — including exact named third-placed teams via FIFA's official
  best-8-of-12 assignment table.
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
| 2 | **Full FIFA assignment table** for exact named third-placed teams (not a candidate-set stand-in) | User chose BBC-exact. The table guarantees a **bijection** (8 thirds → 8 distinct slots), which *structurally eliminates* the duplicate-team bug a greedy stand-in would risk. |
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

Owns the **best-8-of-12 third-placed** logic.

- `ranked/1` — across all 12 groups, take each group's 3rd-placed row, rank them by Pts → GD → GF
  (same tiebreak), return the ordered list with a **cutoff at 8** and `provisional_cutoff_tie?` set
  when rows 8 and 9 are level (the decisive boundary).
- `assignment/1` — given the **set of 8 groups** currently supplying qualifying thirds, return a map
  `slot_group_letter => occupant_group_letter` via the **official FIFA assignment table**. Returns
  `:indeterminate` when fewer than 8 groups can yet supply a ranked third (too early to apply the
  table) — the signal for the graceful fallback.

The table is the one piece of hand-sourced data; see **Verification** below for how it's made
trustworthy.

### `Predictex.Bracket` — pure, **total**

Resolves each R32 fixture's two slots into something always renderable. The placeholder parser is an
**anti-corruption boundary**: every input maps cleanly, never raises.

`resolve_slot(placeholder, tables, thirds) ::`
- `"1C"` → `{:exact, winner_of("C")}` (rank 1 of group C, or `{:tbd, "Winner C"}` if C has no rank-1 yet)
- `"2F"` → `{:exact, runner_up_of("F")}` (rank 2, or `{:tbd, "Runners-up F"}`)
- `"3A/B/C/D/F"` →
  - if `Thirds.assignment/1` resolves this slot to group *G* and *G* has a ranked third →
    `{:exact, third_of(G)}`
  - else → `{:candidate_set, ["A","B","C","D","F"]}` (graceful fallback — honest uncertainty)
- a real team name (`"Germany"`) → `{:resolved, "Germany"}` (openfootball already settled it;
  projection == actual)
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

## Verification (what makes a hand-sourced table trustworthy)

The 495-row (C(12,8)) assignment table is the only error-prone artifact. Three guards:

1. **Research spike first** (`docs/superpowers/research/2026-06-25-...`): pin the authoritative
   source for the 2026 best-8-of-12 table (FIFA regulations / Wikipedia "2026 FIFA World Cup
   knockout stage"), and determine whether the per-slot candidate sets force a **unique** matching —
   if they do, compute the assignment by bipartite matching and skip hand-entry; if not, encode the
   published table. The spike's verdict decides the implementation shape.
2. **Golden cross-check test** (à la `c9s` flags snapshot): regenerate each slot's candidate set as
   the union, across all 495 combinations, of the table's assignments, and assert it **equals** the
   candidate sets FIFA already stamped on our R32 fixtures (`3A/B/C/D/F` …). A wrong/typo'd row
   breaks this. The R32 placeholder sets are frozen into a fixture file (the stand-in for the live
   feed CI can't fetch), regenerated via a documented command.
3. **Bijection property** (StreamData over combinations): for every set of 8 qualifying-third groups,
   `assignment/1` maps the 8 thirds to **8 distinct slots**, each respecting that slot's candidate set.

Plus the **total-function** guarantee: any lookup miss or incomplete data degrades to the
candidate-set rendering rather than raising — BBC-exact when resolvable, honest-uncertain otherwise,
never broken.

## Testing

- `GroupTables`: unit + property tests over crafted 12-group universes — full results, partial
  results (mid-stage), exact ties (provisional marker), own-goal scorelines, a group with 0 played.
- `Bracket.Thirds`: `ranked/1` cutoff + 8/9 provisional tie; `assignment/1` bijection property +
  `:indeterminate` early-stage path; the golden candidate-set cross-check.
- `Bracket`: `resolve_slot/3` totality (every placeholder shape incl. garbage → renders), exact vs
  candidate-set vs resolved-real-name vs tbd; full `build/2` over a seeded universe.
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
