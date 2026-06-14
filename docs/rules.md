# FIFA Match Predictor — Game Rules

> Reference document for the World Cup prediction game. Source of truth for scoring,
> rounds, prediction mechanics, and leagues.

## 1. Introduction

Welcome to FIFA Match Predictor. Players predict the outcome of every match at the
FIFA World Cup 2026™ and earn points based on the accuracy of their predictions.
Players compete against friends and millions of users worldwide.

## 2. Registration

- Completely **free** to play.
- To save predictions, track progress throughout the tournament, and compare against
  other users, a player must log in or create a **FIFA ID**.

## 3. Making Predictions

- Predictions are entered on the **My Predictions** page, where a player enters a
  scoreline for each fixture in an upcoming Round.
- There are **8 Rounds** total: 3 in the Group Stage and 5 in the Knockout Stage.
- **Group Stage:** predict the **scoreline** only.
- **Knockout Stage:** predict the scoreline **plus**:
  - the **first team to score**, and
  - the **first player to score**.

## 4. Rounds

| Stage            | Round                              |
| ---------------- | ---------------------------------- |
| Group Stage      | Round 1                            |
| Group Stage      | Round 2                            |
| Group Stage      | Round 3                            |
| Knockout Stages  | Round of 32                        |
| Knockout Stages  | Round of 16                        |
| Knockout Stages  | Quarter-Finals                     |
| Knockout Stages  | Semi-Finals                        |
| Knockout Stages  | Final (inc. 3rd Place playoff)     |

**Availability rules:**

- All **three Group Stage Rounds** can be predicted right away.
- Each **Knockout Stage Round** only opens for predictions once **all fixtures from
  the previous Round have been completed**.

## 5. Booster 2X

- For **one fixture in each Round**, a player can activate their **2X Booster** to
  earn **double points** on that fixture.

## 6. Lockout

- Predictions for a fixture can be entered/edited up until **kick-off**, at which
  point that fixture **locks**.
- Other (unplayed) fixtures in the same Round remain editable.

## 7. Scoring

Points are awarded per prediction based on accuracy:

| Prediction                                                                                                  | Points      |
| ---------------------------------------------------------------------------------------------------------- | ----------- |
| Correct Outcome                                                                                            | +10 points  |
| Correct Goals (Home Team)                                                                                  | +5 points   |
| Correct Goals (Away Team)                                                                                  | +5 points   |
| Correct Goal Difference                                                                                    | +5 points   |
| Correct Score Bonus                                                                                        | +5 points   |
| Risky Prediction Bonus (correctly predict a Home/Away win when **< 20%** of users predicted the same outcome) | +10 points  |
| Correct First Team to Score                                                                                | +5 points   |
| Correct First Player to Score**                                                                            | +10 points  |
| Round Bonus (correctly predict **all** outcomes in a Round)                                                | +20 points  |

\* **Knockout Stage:** points are awarded based on the **full-time** result. Example:
if a match ends 2–2 and then goes to extra time or penalties, points are awarded based
on the 2–2 score.

\*\* If the **first goal** in a match is an **own goal**, **no points** are awarded for
the First Player to Score prediction.

## 8. Leagues & Leaderboards

- Every player is automatically added to the **Overall Leaderboard** (global ranking).
- Players can also:
  - Create or join **Public Leagues** (no invite required), or
  - Set up a **Private League** with friends.

## 9. Domain notes — implementation contract

These resolve ambiguities in the player-facing rules above. They are the contract the
scoring engine tests assert against. Settled by advisor review on 2026-06-14.

### Settled rulings

1. **Scoring components are additive.** A correct exact score fires Correct Outcome (+10),
   Correct Home Goals (+5), Correct Away Goals (+5), Correct Goal Difference (+5) and
   Correct Score Bonus (+5) simultaneously — base +30 before booster/round bonus.
2. **Risky Bonus cohort = FIFA's global %**, entered by the admin per fixture (FIFA blocks
   scraping, so this is manual). The bonus is skipped when the cohort % is absent. It
   applies only to a correct **Home or Away win** prediction (never a draw) when the
   relevant side's cohort % is `< 20`.
3. **Booster 2× doubles the fixture total only** — *not* the +20 Round Bonus. Booster usage
   mirrors FIFA: boosters a player already spent (we join mid-tournament) are captured on
   import / manual entry, not re-chosen in-app.
4. **Knockout scoring uses the full-time (regulation) result, excluding extra time and
   penalties.** Verified against openfootball: `score.ft` is regulation-only (2022 final =
   `ft:[2,2]`, with `et:[3,3]` and `p:[4,2]` held separately and ignored).
5. **Own goals:** void **First Player to Score** (+0), but **First Team to Score still
   scores**, credited to the beneficiary side.
6. **Scoring window:** only fixtures from our mid-tournament join onward are scored (first
   scored fixture: Egypt–Belgium, 20:00 UK, 2026-06-14). Earlier fixtures are excluded.

### openfootball data contract (`openfootball/worldcup.json`)

- `score: {ft, ht, et?, p?}` — arrays `[team1, team2]`. Use **`ft`** for all scoring.
- Goals live in `goals1` (team1) / `goals2` (team2), **listed under the team the goal
  counts for** (the beneficiary) — including own goals. An `owngoal: true` entry names the
  player who scored into their own net but sits in the **opponent's** (beneficiary's) array.
- Derive **first team to score** = the side whose array holds the earliest goal, ordered by
  `(minute, offset || 0)` (`offset` = stoppage-time minutes). Derive **first player to
  score** from that same goal, voided if it is `owngoal: true`.
- This derivation belongs to the **ingestion layer**, not the scoring engine. The scoring
  engine is a **pure function** over already-derived fields.
