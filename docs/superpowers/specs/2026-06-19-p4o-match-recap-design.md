# p4o — Match recap: points-per-player + goal breakdown

**Status:** design approved 2026-06-19 · **Issue:** predictex-p4o · **Relates:** i1s (replay), hco/i9k (knockout), bdq (cards)

## Context & goal

The per-fixture page (`/fixtures/:id`, `PredictexWeb.FixtureLive`) has three states today:
pre-kickoff (picks hidden, anti-copy), live (what-if scenarios + buzz headlines), and
post-kickoff-locked ("Everyone's picks" — each player's predicted scoreline + ⚡ booster).

It has **no settled-match recap**: once a fixture finishes, `is_live` is false, so the page
shows teams + "v" + kickoff time + predicted scorelines — but not the final score, not the
points each pick earned, and not what actually happened in the match.

This adds a **settled-match recap** with two enrichments:

1. **Points-per-player** — for the settled fixture, the leaderboard points each member's pick
   on *this* fixture yielded.
2. **Goal breakdown** — each goal: scorer name, type (penalty / own-goal / regular), attributed
   to the scoring side.

## Scope

**In scope:** group-stage settled fixtures (`status == :completed`, `round.stage == :group`).

**Explicitly out of scope (deferred — see "Deferred decisions"):**
- **Knockout / extra-time recap.** openfootball's `home_goals`/`away_goals` is the **regulation**
  FT score; its `goals1`/`goals2` arrays **include ET goals** (verified against WC2022:
  Croatia-Brazil `ft [0,0]` lists 2 goals at 105'/117'; Argentina-France `ft [2,2]` lists 3 each
  incl. 108'/118'). So a knockout-to-ET recap would show more goals than the header score under
  *both* sources, and FIFA reconciliation (below) always fails into that same broken state.
  Group stage has no ET, so scope there now and defer KO. Requirements for the KO recap are
  captured below so they aren't lost before the first knockout (2026-06-28).
- **Cards** — split to predictex-bdq (deferred until a red/2nd-yellow is captured and the Card
  enum is verified from data).

## Data model

New embedded list on the `fixtures` schema (keep it a **typed embedded schema**, not raw jsonb
maps, so the LiveView receives validated structs — per the "validated data before the LiveView"
rule):

```
embeds_many :goals, Predictex.Tournament.Fixture.Goal  # backed by {:array, :map} jsonb column
  field :side,   Ecto.Enum, values: [:home, :away]
  field :type,   Ecto.Enum, values: [:penalty, :own_goal, :regular]
  field :player, :string
  field :minute, :string   # string to carry stoppage notation ("90+9")
```

Migration: additive `add :goals, {:array, :map}, default: []`. No backfill — populated on the
next ResultSync. openfootball **owns** `goals` (same two-writer rule as the result columns), so
`:goals` joins `@replace_on_conflict` in `Results.Ingest` — re-sync overwrites it.

## Pure decoders → one unified event shape

Both decoders emit the same shape, ordered by elapsed minute:
`%{side: :home | :away, type: :penalty | :own_goal | :regular, player: String.t() | nil, minute: String.t()}`

- **`Results.Openfootball.goal_events/1`** — extends the module that already parses `goals1`/
  `goals2` for first-scorer. Side from array (goals1 → :home, goals2 → :away); `penalty: true` →
  `:penalty`, `owngoal: true` → `:own_goal`, else `:regular`; minute from `minute` (+ `offset`).
  This is the shape persisted into `fixtures.goals` via Ingest.
- **`Predictex.Capture.goal_events/1`** — lifted from the goal logic already inside `analyze/1`
  (Type enum 1 → `:penalty`, 2 → `:regular`, 3 → `:own_goal`; side = which `Goals` array;
  scorer name via the `Players` locale map). `analyze/1` is refactored to reuse it — no behaviour
  change to the summary report.

Own-goal attribution rule (already encoded for first-scorer): the scoring **side is the array the
goal sits in**, never the scorer's roster team.

## Recap read model — `Predictex.MatchRecap`

Pure core, single DB read at the edge.

`MatchRecap.build(fixture, predictions, fifa_body | nil) :: %{points_by_player, goals, source}`:

- **points_by_player** — `%{player_id => fixture_total}` via `Scoring.score(pred, fixture,
  fixture.round.stage).fixture_total` (booster already folded in by `score/3`; no new scoring).
  This is the **per-fixture** contribution and deliberately **excludes** the round bonus (a
  round-level award), so it will not sum to the leaderboard total — the UI labels it as
  per-fixture points to pre-empt "the arithmetic doesn't add up" (same reconciliation MyPredictions
  already does).
- **goals + source** — if `fifa_body` is present **and** the FIFA-decoded goals **reconcile** with
  the final score, use them (`source: :fifa`); otherwise use the persisted openfootball
  `fixture.goals` (`source: :openfootball`). Reconciliation is a **count check** — per-side goal
  count (own-goals credited to the beneficiary side) equals `home_goals`/`away_goals`. It guards
  against a short FIFA Goals array from an incomplete capture; it does **not** verify scorer/type
  content. (`source` is computed but not surfaced in the UI this iteration — YAGNI.)

Edge: `FixtureLive` does the one read — `Capture.list_snapshots(fixture.fifa_match_id)` → latest
`detail` body with a map payload (nil when none) — then calls the pure `build/3`.

## FixtureLive changes

- Preload `fixture.round` (Scoring needs `stage`).
- Settled (`status == :completed`, group): show the **final score** in the header (replacing "v");
  render a **goal-breakdown** section (e.g. `23' Scorer (pen)` grouped by side; "No goals." when
  the list is empty, e.g. a 0-0); annotate each pick in "Everyone's picks" with its points
  (`2–1 ⚡2× +45`).
- Live and pre-kickoff states unchanged.

## Deferred decisions (captured so they aren't lost)

- **Knockout/ET recap (before 2026-06-28, on hco/i9k):** the KO recap must (a) show the result
  that actually decided the tie — ET score and, where applicable, the penalty shootout, not just
  regulation `ft`; (b) reconcile the goal breakdown against the **right total** (et goals, with
  pens shown separately, not the regulation ft); (c) make the header score unambiguous for a
  pens win (a 1-1 that went to pens must not read as a draw). Until then, the recap renders only
  for group-stage fixtures.
- **Cards (bdq):** add to the breakdown once a card source/enum is verified from captured data.

## Testing

- `Results.Openfootball.goal_events/1` — regular / penalty / own-goal; side attribution; ordering;
  stoppage minute.
- `Predictex.Capture.goal_events/1` — from an **inline** sample FIFA detail body (shape per bd
  memory `fifa-v3-live-api-contract`: nested `HomeTeam/AwayTeam` `Goals` + `Players`, Type enum,
  own-goal under beneficiary side); not the gitignored `tmp/` baselines. `analyze/1` unchanged
  (regression).
- `MatchRecap.build/3` — FIFA used when it reconciles; falls back on count mismatch; falls back on
  nil body; points include the booster; points exclude the round bonus.
- `Results.Ingest` — persists `goals`; re-sync overwrites them.
- `FixtureLive` full-flow — a group settled fixture renders final score + per-pick points + goal
  breakdown; FIFA-source and openfootball-source paths both render; 0-0 shows "No goals."
- Migration.

## Sequencing — two independently-shippable slices

1. **Points-per-player** — pure recompute off `Scoring.score`, **no migration**. Lands + deploys
   on its own.
2. **Goal breakdown** — migration + the two decoders + `MatchRecap` reconciliation + Ingest +
   the breakdown UI. Lands after part 1.
