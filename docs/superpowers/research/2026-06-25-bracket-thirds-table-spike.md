# Spike: sourcing/verifying the FIFA best-8-of-12 third-placed assignment table

- **Bead:** `predictex-7qu`
- **Date:** 2026-06-25
- **Question:** for the `/bracket` "as it stands" feature, can we resolve the eight R32
  third-placed slots to **exact named teams** in a way that is (a) correct and (b) verifiable in
  CI — or must we fall back to the candidate-set rendering?

## TL;DR — verdict

**Do NOT hand-encode the 495-row FIFA table.** Two findings kill the full-table path under our
constraints:

1. The per-slot candidate sets do **not** determine the assignment — every one of the 495
   qualifying-third combinations admits **multiple** valid matchings (3–214 each; **zero** unique).
   So FIFA's table is genuinely required to pick the one true assignment.
2. The authoritative table (FIFA Competition Regulations **Annex C**; mirrored on Wikipedia) is
   **human-readable only** — no machine-readable source found. Transcribing 495 rows × 8
   assignments by hand is error-prone, and our planned **golden candidate-set cross-check cannot
   catch a wrong row**: because each combination has many *valid* matchings, a mistranscribed but
   still-valid row passes the check silently. CI also can't fetch the live source.

For a feature whose projection shelf-life is ~3 days (now → 28 Jun), that is a poor trade:
high effort, fragile data, weak verification, narrow window.

**Recommendation:** the **candidate-set rendering** (third-slots as "3rd · {set}" + a ranked
best-thirds panel), with **exact named thirds arriving automatically at group-stage end** via the
existing openfootball + `Workers.KnockoutIds` ingest (which applies FIFA's table for us and resolves
the real R32 teams in place ~28 Jun). We get BBC-exact thirds at the moment they become real, for
zero fragile data and full verifiability. The only thing forgone is exact *named-projected* thirds
during the mid-stage churn window — exactly the part that needs the unverifiable table.

## Experiment 1 — do the candidate sets force a unique matching?

The 8 R32 third-place slots and their candidate group sets, read from FIFA `rounds.json` via the
prod R32 fixtures (`source_num` → `team2` placeholder):

| R32 match (`source_num`) | third-slot candidate set |
|---|---|
| 74 | A B C D F |
| 77 | C D F G H |
| 79 | C E F H I |
| 80 | E H I J K |
| 81 | B E F I J |
| 82 | A E H I J |
| 85 | E F G I J |
| 87 | D E I J L |

For each of the C(12,8)=495 ways to choose which 8 groups supply qualifying thirds, count the
perfect matchings of those 8 groups to the 8 slots respecting candidate sets (backtracking count).

**Result:**
- Total combinations: 495
- Combinations with **exactly one** matching: **0**
- Combinations with **multiple** matchings: **495** (distribution ranged 3 … 214)
- Combinations with **zero** matchings: 0

**Interpretation:** the candidate sets are merely the *union of possibilities* per slot; they never
pin a single assignment. FIFA's table chooses one (to balance the bracket / keep group-mates apart).
So we cannot compute the assignment from our data — the table is mandatory for exact projection.

(Script: `scratchpad/thirds_spike.py` — pure combinatorics, reproducible.)

## Experiment 2 — does an authoritative, sourceable table exist?

- **Yes, authoritative:** FIFA Competition Regulations **Annex C** publishes all 495 scenarios in
  advance; Wikipedia mirrors it (`Template:2026 FIFA World Cup third-place table`, "Combinations of
  matches in the round of 32"). ~246/495 still mathematically possible as of the spike date.
- **No machine-readable source:** web search surfaced only human-readable explainers and the
  regulations PDF / Wikipedia table. No JSON/CSV dataset. Our only web-content tool (`WebFetch`)
  routes through a summarizing model, so it cannot faithfully transcribe 495×8 data points either.

So the table can only enter the codebase by **hand transcription** — the exact fragile path the
verification was meant to eliminate, and which the golden cross-check (Experiment 1's corollary)
cannot validate.

## Consequence for the spec

The spec's "full FIFA table + golden cross-check + bijection property" verification story is
**unsound**: the bijection property holds for *many* wrong tables, and the golden cross-check only
proves validity, not FIFA-correctness. Either:

- **(A — recommended)** switch the spec's third-slot rendering to the candidate-set view (this was
  the advisor's original recommendation; the spike now confirms it on evidence), with exact thirds
  via the existing 28-Jun ingest; or
- **(B)** keep the full table but accept: manual transcription of 495 rows from Annex C, no CI
  correctness check (only a manual eyeball vs the source, and a post-hoc reconciliation against
  openfootball's actual resolution after 28 Jun), for ~3 days of mid-stage value.

This is a user decision — it changes what the spec says. Findings handed back for re-decision.

## Sources
- [Template:2026 FIFA World Cup third-place table — Wikipedia](https://en.wikipedia.org/wiki/Template:2026_FIFA_World_Cup_third-place_table)
- [2026 FIFA World Cup knockout stage — Wikipedia](https://en.wikipedia.org/wiki/2026_FIFA_World_Cup_knockout_stage)
- [The 495 Scenarios Explained: World Cup 2026 Round of 32 Rules — worldcuplocaltime.com](https://worldcuplocaltime.com/world-cup-2026-495-scenarios-round-of-32/)
- [2026 World Cup Third-Place Group Table: How It Works — SI.com](https://www.si.com/soccer/2026-world-cup-third-place-group-table-how-it-works-as-things-stand)
- FIFA World Cup 2026 Competition Regulations, Annex C (third-placed allocation).
