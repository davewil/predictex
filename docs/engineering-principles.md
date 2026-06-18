# Engineering Principles for Production Software

Lessons learned from building and deploying Slackex. These principles apply to any production system and should be enshrined in tooling, not just documentation.

> This document is the **concrete, project-specific instantiation** of the delivery philosophy in [`software-delivery-principles.md`](software-delivery-principles.md). That doc is the project-agnostic *why* (Lean flow, trunk-based development, jidoka, dark shipping, expand/contract); this one is the *how* for this repo — the actual gate, hooks, migration safety, and deploy rules. Read the philosophy first if you want the reasoning behind the rules below.

## 1. Never Break Production

**Every change must be proven safe before it reaches production.** "It works on my machine" is not evidence. "CI passed" is necessary but not sufficient.

### The Shift-Left Principle

Nothing that can break production build, test, or deployment may reach the CI/CD pipeline. Every failure class that CI checks for must have a local equivalent that catches it before `git push`.

**Implementation:**
- Pre-commit hooks run the same checks as CI (formatting, tests, linting, YAML validation).
- Pre-deploy scripts verify the full production surface (Docker build, release boot, infrastructure config).
- When CI catches something the hook missed, fix the tooling gap first, then fix the bug.
- When adding a new CI check, add the local equivalent in the same commit.

**Claude Code automation:**
- `PreToolUse` hook on `Bash`: Block `git commit --no-verify` to prevent hook bypass.
- `scripts/pre-commit`: Git pre-commit hook (formatting, tests, YAML lint).
- `scripts/pre-deploy`: Full production surface verification before tagging.
- `/deploy` slash command: Automates pre-deploy + tag + push workflow.

### Pre-Deploy Verification

Tests passing is necessary but not sufficient. Before every deploy:

1. Tests pass with zero failures
2. Formatting, linting, static analysis clean
3. Docker image builds successfully
4. Docker image boots and runs a basic eval command
5. Infrastructure config (YAML, Dockerfiles, compose files) is valid
6. If clustering/distribution changed, verify nodes discover each other post-deploy

**Implementation:**
- Automated `scripts/pre-deploy` script runs all checks.
- CI deploy workflow includes smoke tests (health endpoint on every container).
- Post-deploy cluster size verification.

---

## 2. Deploy-Safe Changes Only

**The running application must never break during a deploy.** Old code must work with new schema. New code must work with old schema (during the rollout window).

### Expand / Contract Pattern

Database changes follow a two-phase approach:

**Expand phase (deploy N):**
- Add columns as nullable (or with defaults)
- Add new tables freely
- Add indexes concurrently
- Keep old columns/tables in place

**Contract phase (deploy N+1 or later):**
- Remove old columns/tables only after code using them is deployed and stable
- Add NOT NULL constraints only after backfilling
- Drop unused indexes

**Never in a single migration:**
- Rename a column or table
- Change a column type
- Add a NOT NULL column without a default
- Drop a column still referenced by running code

**Claude Code automation:**
- `PreToolUse` hook on `Write`/`Edit`: Scan migration files for unsafe patterns (NOT NULL without default, renames, type changes, drops). Warn before writing.

### Feature Flags

All new user-facing features deploy behind a feature flag (off by default). The lifecycle:

1. **Develop** behind `flags.enabled?(:feature, for: user)`
2. **Deploy** — code ships, invisible to users
3. **PO validates** — enable for test users via admin UI
4. **Release** — enable globally
5. **Contract** — remove flag check in follow-up PR

**Rules:**
- Guard both UI and logic (don't rely on UI hiding alone)
- One flag per feature, descriptive names
- Clean up flags promptly after global enable

---

## 3. Test Isolation is Non-Negotiable

**Tests must be hermetic.** No test should be able to affect another test's outcome.

### Shared State is the Enemy

Global shared state (ETS tables, Redis, file system, GenServer registries) persists across tests. `async: false` only serializes within a module, NOT across modules.

**Principles:**
- Centralize cleanup in test case templates (DataCase, ConnCase), not scattered across individual test modules.
- Clean shared state both before (setup) and after (on_exit) every test.
- Never write incomplete/synthetic data to shared caches in tests. Use realistic data shapes that won't crash downstream code if they leak.
- Never stuff synthetic data into GenServer state without cleaning it up before test exit.

**Root cause pattern (ETS cross-contamination):**
```
Test A writes %{id: 1} to shared ETS (incomplete map)
    |
Test B's GenServer.init reads from ETS cache
    |
Gets %{id: 1}, tries to process it
    |
Crashes on missing :content key
    |
Flaky test failure (only when A and B interleave)
```

**Fix pattern:**
```
DataCase.setup_sandbox/1:
  - :ets.delete_all_objects(:cache_table)  # before test
  - on_exit(fn -> :ets.delete_all_objects(:cache_table) end)  # after test
```

**Claude Code automation:**
- CLAUDE.md documents the ETS isolation rules as hard requirements.
- DataCase/ConnCase templates enforce cleanup automatically.

---

## 4. Root Cause, Not Workarounds

**Never hide the underlying issue with a defensive fix.** Defensive code is a legitimate safety net for production, but it must never be the primary fix.

When a test fails:
1. Find the actual root cause
2. Fix the root cause
3. Add a defensive fallback as a safety net (optional)
4. Document why the defensive code exists

When a deploy fails:
1. Fix the deploy issue
2. Add the check to the pre-deploy script so it can't happen again
3. Update CLAUDE.md deployment discipline with the lesson learned
4. If the failure class was catchable locally, add it to pre-commit hooks

**Anti-patterns:**
- Adding `rescue` blocks to silence errors
- Skipping tests that "sometimes fail"
- Adding `|| true` to deploy commands that fail
- Deleting code that crashes instead of understanding why

---

## 5. Automate Everything

**If a human must remember to do it, it will eventually be forgotten.** Manual steps are bugs waiting to happen.

### Automation Hierarchy

From least to most effective:

1. **Documentation** — write it down (CLAUDE.md, README)
   - Lowest effort, lowest reliability. People don't read docs.

2. **Checklists** — structured steps to follow
   - Better than prose, but still requires discipline.

3. **Scripts** — automate the checklist
   - `scripts/pre-deploy`, `scripts/pre-commit`
   - Reliable if people run them.

4. **Hooks** — run scripts automatically
   - Git pre-commit hooks, CI/CD pipelines
   - Can be bypassed (`--no-verify`).

5. **Enforcement hooks** — block bypass attempts
   - Claude Code `PreToolUse` hook blocking `--no-verify`
   - CI checks that fail the pipeline
   - Cannot be bypassed without changing the hook itself.

**Principle:** Start at level 1 (document the lesson), then immediately climb to the highest automation level that's practical. Don't stop at documentation.

### Claude Code Hook Types

| Hook Type | Trigger | Use Case |
|-----------|---------|----------|
| `PreToolUse` on `Bash` | Before shell commands | Block dangerous commands (`--no-verify`, `--force`) |
| `PreToolUse` on `Write`/`Edit` | Before file modifications | Validate migration safety, CI config patterns |
| `PostToolUse` on `Write`/`Edit` | After file modifications | Remind to run tests, verify changes |
| `Stop` | Before conversation ends | Check for uncommitted changes, remind about deploy |

### Slash Commands

Custom `/deploy` command wraps the full workflow: verify -> tag -> push. Eliminates manual version calculation and forgotten pre-deploy checks.

### Decision: Two-Tier Mermaid Gate (2026-06)

Mermaid diagram validation runs in two tiers with **different blocking semantics** — a recorded exception to the single-gate ideal:

- **Parse tier (blocking)**: `scripts/mermaid/validate.mjs` — the real Mermaid parser plus a static C4 Rel-to-boundary heuristic, no browser, seconds. Runs in `scripts/pre-deploy`; a failure blocks tagging.
- **Render tier (advisory)**: `scripts/mermaid/render-check.sh` — mermaid-cli + Chrome actually lays out every diagram, catching render crashes parsing cannot. Runs as the `mermaid-render` CI job; a failure is a red X that deliberately does **not** block the deploy path.

**Why the seam is acceptable here:** the render tier validates documentation only — a broken diagram cannot break production code, so holding a code deploy hostage to a docs render is the wrong trade against fast feedback (the render pass costs minutes of Chrome startup per doc). The parse tier still blocks the common failure class locally.

**What promoting the render tier to blocking would require** (if a render-crashed diagram ever ships and matters): install mermaid-cli in pre-deploy and run `render-check.sh` there instead of `validate.mjs`, delete `validate.mjs` (including the C4 heuristic that exists only to approximate rendering), and accept ~1–2 minutes added to pre-deploy. That consolidation removes the dual mermaid version pin and one whole npm project.

**Version-sync invariant:** both tiers must validate the same Mermaid grammar. The single source is `scripts/mermaid/package.json` — `dependencies.mermaid` (parse tier) and `config.mermaid-cli` (render tier, read by CI at install time) must be bumped together.

---

## 6. Infrastructure Config is Code

**Dockerfiles, compose files, CI workflows, Caddyfiles, and release configs are production code.** They deserve the same rigor as application code.

### SSH Heredoc Rules

When deploying via SSH heredocs in CI:
- Redirect stdin from `/dev/null` on interactive commands (`docker compose exec ... < /dev/null`). Without this, the command consumes the heredoc.
- Redirect stderr to stdout (`2>&1`) on all compose commands. CI doesn't forward stderr from SSH.
- Add echo markers before and after every step. Silent failures are invisible.
- Use `printf` instead of heredocs inside YAML block scalars. Nested heredoc terminators break YAML parsing.

### Docker Image Rules

- Verify runtime dependencies exist in the runtime stage (curl, openssl, etc.)
- Build the Docker image locally before tagging (`docker build -t app:local .`)
- Boot the image and run a basic eval command to verify the release starts

### Reverse Proxy Rules

- Use `restart`, not `reload`, after recreating backend containers (DNS caching)
- Enable active health checks for automatic failover
- Never dump proxy config to CI logs (may contain API tokens)

---

## 7. Lessons Are Permanent

**Every production incident produces a lasting improvement.** The cycle:

1. **Incident occurs** — deploy fails, bug reaches production, flaky test blocks CI
2. **Fix the immediate issue** — get production back to working state
3. **Root cause analysis** — understand *why* it happened, not just *what* happened
4. **Prevent recurrence** — add automation (hook, script, test, CI check)
5. **Document the lesson** — update CLAUDE.md, this principles doc, RCA docs
6. **Verify the prevention works** — the same failure class should now be caught locally

**The tooling gap rule:** If CI (or production) catches something that could have been caught locally, that is a tooling gap. Fix the gap before fixing the bug.

---

## Quick Reference: Automation Checklist for New Projects

### Day 1
- [ ] Pre-commit hook: formatting, linting, fast tests
- [ ] CI pipeline: full test suite, static analysis
- [ ] CLAUDE.md: project overview, test commands, deployment process

### Before First Deploy
- [ ] Pre-deploy script: tests + Docker build + release boot verification
- [ ] CI deploy workflow: smoke tests on every container
- [ ] CLAUDE.md: deployment discipline section

### Ongoing
- [ ] Claude Code hooks: block `--no-verify`, migration safety, CI config validation
- [ ] `/deploy` slash command: automates verify -> tag -> push
- [ ] RCA documents for every production incident
- [ ] Update CLAUDE.md after every new failure class

### Per Feature
- [ ] Feature flag wrapping new user-facing behaviour
- [ ] Deploy-safe migrations (expand/contract)
- [ ] Tests covering both flag-on and flag-off paths
