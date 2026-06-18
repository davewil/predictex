# Software Delivery Principles

**Status:** Reference · Portable
**Scope:** The delivery philosophy that underpins how this codebase is built and shipped — Lean flow, trunk-based development, build-quality-in, and the mechanisms that make small-batch delivery safe. This document is deliberately **project-agnostic**: no language, framework, or tooling is named. It is the *why*. For the *how* in this specific project, see [`engineering-principles.md`](engineering-principles.md).

> Reuse note: This file is meant to be copied verbatim into other repositories. It states principles, not implementations. Each project instantiates them with its own stack (its own gate, flag system, migration tooling) and records that instantiation in its own `engineering-principles.md` and `CLAUDE.md`.

---

## 1. The Goal

**A continuous flow of small, safe changes into production.**

Everything below serves that one sentence. Value is only realised when a change reaches users; until then it is inventory. So the objective is not "write code" or "pass review" — it is to *shorten the time and shrink the batch* between an idea and it running in production, without ever trading away safety to do it.

Two forces are in tension and must both be held:

- **Speed / small batch** — integrate constantly, in tiny increments.
- **Safety / quality** — never break production.

The naive resolution is to slow down for safety (big batches, long-lived branches, heavy review gates) or to speed up by cutting corners (skip checks, ship untested). Both are failures. The principles here are the techniques that let you have both at once — and the moment a practice forces a choice between them, that practice is the thing to fix.

---

## 2. The Lean Lens: Muda, Mura, Muri

Lean names three enemies of flow. They are useful because they let you *see* waste that otherwise hides as "just how we work."

| Term | Meaning | How it shows up in software delivery |
|---|---|---|
| **Muda** | Waste — activity that adds no value | Unmerged work (inventory), waiting for review, rework from merge conflicts, re-discovering lost context, defects |
| **Mura** | Unevenness — irregular, spiky flow | Big-bang merges, release trains, crunch-then-idle cycles, batched reviews |
| **Muri** | Overburden — overloading people or systems | A reviewer handed a huge diff, an author holding unintegrated context in their head, context-switching |

The crucial relationship: **Mura causes Muda and Muri.** Irregular, large batches are what *create* both the waste and the overburden. Smooth, level flow of small changes (Lean calls it *heijunka*) is the root-cause fix, not a nice-to-have.

### Stacked changes are the canonical waste

A change that sits unmerged — on a branch, in a review queue, "almost done" — is not progress. It is:

- **Inventory (Muda):** finished work depreciating on a shelf, delivering zero value.
- **A rework tax (Muda):** main moves underneath it, so the longer it waits the more merge-conflict resolution — pure defect-correction — it will cost. Rework is the worst waste: effort spent producing nothing new.
- **Overburden (Muri):** it forces the author to keep unintegrated context live in memory, and hands the reviewer a larger, riskier batch precisely when review quality matters most.
- **Unevenness (Mura):** batching turns a steady trickle of small integrations into lumpy big-bang merges.

> Work waiting for review is waste. Treat the review queue and the unmerged branch as inventory to be eliminated, not as a normal state of the world.

---

## 3. One-Piece Flow: Trunk-Based Development

The antidote to batching is **one-piece flow**: integrate one small change at a time, continuously, into the shared trunk.

- **Small commits straight to the main line.** No long-lived feature branches by default. Each commit is a complete, safe, integrable increment.
- **Branches are an exception, not the workflow.** Every branch is a small bet that the cost of isolation is worth it; that bet usually loses, because isolation *is* the inventory you are trying to avoid.
- **Integrate to reduce risk, not after risk is gone.** Frequent integration is how you *discover* conflicts and breakage while they are still one-line problems.

This only works if two things are true: every increment can be made safe on its own (Sections 5, 7, 8), and integration is cheap and fast (Section 6). Trunk-based development without those is just shipping breakage faster. With them, it is the highest-flow, lowest-waste way to deliver.

**Trunk-based is a principle to defend, not a convenience to abandon under pressure.** When it starts to hurt, the hurt is a signal that one of its supports has weakened — the gate got slow, or changes stopped being independently safe. Fix the support. Abandoning trunk-based (reverting to branches and batches) to relieve the symptom reintroduces every M in Section 2.

---

## 4. Build Quality In: Jidoka

Lean's *jidoka* means **build quality in at the source** and **stop the line** the instant a defect appears — never knowingly pass a defect downstream.

In delivery terms: quality is enforced at the point of integration by an **automated gate** that runs the same checks that would otherwise fail later (format, lint, static analysis, tests, config validation). A change that fails the gate does not become a commit.

The defining property of a good gate:

> **There must be no exploitable seam between local and remote.** "Passes on my machine" and "passes in CI" cannot diverge, because the same gate is the single enforcement point and it runs *before* the change can land.

If local checks are a weaker subset of remote checks, an agent or a tired human can take a shortcut that the remote later rejects — relocating the failure to where it is more expensive to find and easier to rationalise around. Closing that seam is worth real cost: it converts "we hope this is right" into "this cannot be wrong in the ways we check for."

Corollaries:

- **Bypassing the gate is a process defect, not a productivity hack.** Disabling the gate for "just this once" (force-skip flags, commenting out checks) defeats jidoka entirely.
- **When the remote catches something the local gate missed, the bug is the second priority.** The first fix is the tooling gap: add the missing check to the gate so that failure class can never reach the remote again.
- **Every recurring failure class earns a permanent check.** Lessons become automation, not folklore.

---

## 5. Fast Feedback Is a First-Class Constraint

Jidoka and one-piece flow only coexist *while the gate is fast.* This is the most important and most overlooked principle in the document.

A slow gate is not merely annoying — it actively destroys trunk-based development:

> When the gate gets slow, the pressure is never "make the gate faster." It is "commit less often." People begin batching changes to amortise the wait — and batching is the abandonment of one-piece flow, disguised as pragmatism. Every M from Section 2 floods back in.

Therefore:

- **Gate runtime is a leading indicator for whether your delivery principle survives.** Watch the trend, not just the absolute number. The danger sign is behavioural: the moment you notice yourself (or an agent) stacking changes to avoid the gate, the gate has *already* cost you the principle, even if it is still nominally "fast enough."
- **Set an explicit feedback budget and defend it.** Define what "fast" means for the project (seconds, ideally; tens of seconds at most for the pre-integration gate). When you breach it, treat it as a defect in the delivery system.
- **The fix is almost always test/check architecture, never a looser gate.** Maximise parallelism; make pure checks pure (no I/O); tier the gate so a fast, *true-subset* of checks runs at commit and the exhaustive set runs before the change reaches the remote — but only if the pre-remote stage stays exhaustive, or you have just reopened the seam from Section 4.
- **Loosening the gate to make it fast is forbidden.** That trades the safety half of Section 1 for the speed half. The whole point is to keep both.

---

## 6. Decouple Deploy from Release: Dark Shipping

To integrate incomplete work to trunk continuously (Section 3) *without* exposing half-built features, separate two things that are usually conflated:

- **Deploy** — the act of getting code running in production.
- **Release** — the act of making a feature visible to users.

**Feature flags** are the mechanism. Incomplete work ships dark: it is deployed, integrated, and exercised by tests, but gated off at every user-facing surface (UI, routes/endpoints, and the logic behind them — never UI-hiding alone). It stays invisible until it is deliberately turned on.

This resolves the apparent contradiction between "integrate constantly" and "don't ship unfinished features." You get continuous integration *and* controlled release.

Flag lifecycle discipline:

1. **Develop** behind the flag, off by default.
2. **Deploy** — the code is live in production but dark.
3. **Validate** — enable for a small audience.
4. **Release** — enable broadly.
5. **Contract** — remove the flag and the dead code path once the feature has graduated.

Two ownership rules keep the system honest:

- **Releasing is a product decision; the Product Owner decides when a flag turns on and when it is ready to be removed.** Flag retirement is not an engineering judgment call left to drift. Engineering's job is to build the feature behind the flag and keep it cleanly removable; the PO's job is to decide when it graduates.
- **A stale flag is waste.** Once a feature is fully released, the lingering flag is a dead conditional and an extra test path — Muda. Retire it promptly (on the PO's call), don't let flags accumulate.

---

## 7. Decouple Migration from Cutover: Expand / Contract

The data and interface analogue of dark shipping. It is what lets schema and contract changes flow in small, safe, independently deployable steps instead of a risky big-bang cutover — so a rolling deploy and a flag-gated feature stay safe.

The rule that makes any deploy safe: **old code must work with the new schema, and new code must work with the old schema, throughout the rollout window.** Achieve it with *parallel change* in phases:

- **Expand:** add the new shape additively and backward-compatibly (new nullable columns, new tables, concurrently-built indexes, new interface alongside the old). Nothing existing breaks.
- **Migrate:** move readers and writers to the new shape; backfill data; run old and new in parallel until the new path is proven.
- **Contract:** remove the old shape only after nothing live depends on it.

Never collapse these into one step (rename-in-place, type-change-in-place, add-NOT-NULL-without-default, drop-while-referenced). Each phase is small, reversible, and independently deployable — the same one-piece-flow discipline applied to migrations.

---

## 8. How It Fits Together

These are not eight separate rules; they are one reinforcing system aimed at the goal in Section 1.

```
            small batch (one-piece flow, trunk-based)  ── §3
                          │ needs
                          ▼
        safe-to-integrate increments
          ├── dark shipping decouples release from deploy   ── §6
          └── expand/contract decouples migration from cutover ── §7
                          │ enforced by
                          ▼
        build quality in (jidoka): one gate, no local↔remote seam ── §4
                          │ only survives while
                          ▼
              feedback stays fast (the budget)  ── §5
                          │ all of which eliminates
                          ▼
                  Muda · Mura · Muri  ── §2
                          │ achieving
                          ▼
        continuous flow of small, safe changes to production ── §1
```

The load-bearing insight: **small batch and fast, safe feedback are not two preferences — they are one system.** Flags decouple release timing, expand/contract decouples migration timing, and the gate guarantees safety — and together they remove every reason a change would need to *wait* or *batch* to be safe. Pull out any one piece and the pressure to batch returns.

---

## 9. Smells: You Are Drifting From These Principles

- Branches living longer than a day; "I'll merge once it's all done."
- A review queue treated as a normal, persistent state rather than waste to eliminate.
- Anyone batching changes to avoid running the gate. (Section 5's danger sign.)
- The gate's runtime trending up with no one treating it as a defect.
- Local checks that are weaker than remote checks. (Section 4's seam.)
- Gate bypasses ("just this once") appearing in history.
- Feature flags accumulating with no owner deciding when they retire.
- Migrations that rename/retype/drop in a single step, or that require a synchronized code+schema cutover.
- A fix that makes the gate pass without making the underlying thing correct.

Each smell maps back to a waste in Section 2. Treat them as line-stop signals.

---

## 10. Adopting These Principles in a New Project

Day one, before the first feature:

- [ ] A single automated gate runs the full quality checks and is wired so nothing reaches the remote without passing it (no local↔remote seam).
- [ ] An explicit feedback budget for the gate is written down, with a plan to defend it (parallelism, pure checks, true-subset tiering).
- [ ] Trunk-based by default: document that branches are the exception.
- [ ] A feature-flag mechanism exists and gates every user-facing surface.
- [ ] Migration tooling/convention enforces expand/contract (and flags unsafe single-step changes).
- [ ] Product Owner ownership of flag enablement and retirement is agreed.
- [ ] A lessons-become-automation loop: every recurring failure class earns a permanent gate check.

Then record the project-specific instantiation (which gate, which flag system, which migration tool) in that project's `engineering-principles.md` and `CLAUDE.md`.

---

## Related Documents

- [`engineering-principles.md`](engineering-principles.md) — this project's concrete instantiation: the actual gate, hooks, migration safety, test isolation, and deploy rules.
- `CLAUDE.md` (repo root) — the agent-facing rulebook that enforces these principles in day-to-day work.
