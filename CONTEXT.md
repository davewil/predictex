# Predictex — Domain Context

Predictex is a FIFA World Cup score-predictor for a private league. Players make
**predictions**; the app scores them against real results and ranks a leaderboard.
This file is the domain glossary; for architecture vocabulary (module, interface,
seam, depth) see the architecture review tooling, not here.

## Prediction intake

**Prediction** (the value):
A player's guess for one **fixture**, validated and ready to persist:
`%{fixture_id, home_goals, away_goals, first_scorer_side, first_scorer_player, booster}` — the
struct `Predictions.Prediction`, the shared shape every **producer** (member form, admin form,
FIFA import) emits through the **prediction-intake boundary**. Distinct from the persisted
**saved prediction** (the Ecto record). _Avoid_: pick (a prediction is a guess about a future
event, not a selection from a fixed set of options), pick row, form row, params map, write row.

**Prediction-intake boundary**:
The pure anti-corruption layer that turns a producer's raw input into validated **predictions**
(the value) and owns the intake invariants (notably **booster**-needs-a-**scoreline**). Returns
`{:ok, [prediction]} | {:error, reason}`; does no persistence. `validate_predictions/1` (renamed
from `validate_pick_rows/1`) is its authoritative core, shared by the form parser and FIFA import.
Persistence trusts its output and writes a **saved prediction**.
_Avoid_: parser, validator (too narrow — it owns invariants, not just shape).

**Producer**:
A source of intake that emits **predictions** (the value) through the **prediction-intake
boundary**. Three exist: the member entry form, the admin-on-behalf form, and FIFA import.

## Core

**Saved prediction**:
The persisted, scored record of a **prediction** — the Ecto entity (today `Predictions.Prediction`;
renamed to `Predictions.SavedPrediction` under this model). At most one per player per **fixture**.
Persistence turns a validated **prediction** (value) into a saved prediction (entity); scoring and
the **leaderboard** read saved predictions. _Avoid_: prediction row, record (too technical), pick.

**Scoreline**:
A player's predicted home–away goal pair for a fixture. The only thing predicted in the group
stage. Distinct from the **result** (the real outcome).
_Avoid_: score, result.

**Booster**:
A player's once-per-**round** multiplier placed on one **fixture**'s prediction. Invariant: a
booster requires a **scoreline** — a booster on a blank **prediction** is rejected (booster-on-blank).
_Avoid_: power-up, multiplier, joker.

**Round**:
One of the 8 predictable stages (3 group, 5 knockout). Carries a `stage` (`:group | :knockout`)
and an `ordinal`. A round is open for predictions until its fixtures lock.
_Avoid_: matchday, gameweek, week.

**Fixture**:
A single match between two teams within a **round**. Locks for prediction at kickoff.
_Avoid_: game, match (use "fixture" for the scheduled row; "match" loosely in prose only).

**Result**:
The real, authoritative outcome of a **fixture** (final regulation score, first scorer), against
which **predictions** are scored. Distinct from a player's **scoreline**.
_Avoid_: outcome, actual.

**FIFA result fallback**:
A bounded exception to openfootball's **result** authority (`Predictex.Results.FifaFallback`): when
openfootball has no result for a played **group** **fixture** but our FIFA capture shows it finished
(`MatchStatus 0`), settle the fixture provisionally from the captured score. openfootball reclaims
authority on its next real-result sync; a `:completed` fixture never reverts to scheduled (the
`Ingest` no-downgrade guard). Knockouts (extra-time / penalties) are out of scope.
_Avoid_: result source, scraper.

**FIFA bracket resolution**:
Provisional filling of knockout **fixture** placeholder slots from FIFA's `rounds.json`
(`Predictex.Fifa.KnockoutTeams`, predictex-e5o): when a KO slot still holds a placeholder side
(`"3B/E/F/I/J"`) but FIFA has resolved the bracket, fill the openfootball-canonical name ahead of
openfootball's sync. openfootball reclaims authority on its next sync (the two-writer rule). Sibling
to **FIFA result fallback** — the same no-downgrade principle applies: only placeholder sides are
written; a resolved side is structurally absent from the output.
_Avoid_: slot resolution, bracket fill.

**Leaderboard**:
The ranked standings. Two boards exist: the cumulative board (all rounds) and the re-based
**knockout** board (knockout rounds only, from zero).
_Avoid_: table, ranking (use for the act of ranking, not the board itself).

## Standings & live buzz

**Ranking core**:
The pure fold every **leaderboard** shares (`Predictex.Ranking`): given already-joined, scored
entries it owns the **fixtures total**, the **Round Bonus** completeness rule, the total, and the
sort — everything the two boards must agree on. No DB. Each board keeps only its **join** (the
DB-backed board resolves a **prediction** to a **fixture** by foreign key; the no-DB CLI board by
normalized team name) and feeds the core. The join is the only real difference between them.
_Avoid_: scorer, aggregator, engine (engine is the **Scoring** rules, not the ranking fold).

**Ranking snapshot**:
The loaded inputs for ranking — every player (with predictions) and every fixture (with its
round) — captured once as `%Standings.Snapshot{}` at a single instant. The pure Gather edge:
`rank`/`project` and all **buzz** projections run over a snapshot without touching the DB, so
one live event loads once instead of per-projection.
_Avoid_: cache, state, dataset.

**Buzz**:
The live "what-if" projections for an in-play **fixture**: re-rank the **leaderboard** under a
few next-goal **scenarios** and turn the movement into shareable headlines. Pure over a
**ranking snapshot**; persists nothing.
_Avoid_: feed, ticker, notifications.

**Scenario**:
One hypothetical next-goal outcome for a live **fixture** (ends now / home scores next / away
scores next), each yielding a projected **leaderboard**.
_Avoid_: case, what-if (in prose only).
