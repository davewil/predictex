# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

```bash
mix setup          # deps, db, assets
mix test           # full suite (creates/migrates the test db first)
mix precommit      # the gate: compile --warnings-as-errors, deps.unlock --check-unused,
                   # format --check-formatted, credo --strict, test — same as CI's Quality job
mix sobelow --skip --exit Low   # security scan (runs in CI; baseline in .sobelow-skips)
```

Static analysis: **credo** (`.credo.exs`; alias-order/alias-usage off, nesting max 3 — see
the comments there) runs in the gate and CI. **sobelow** runs in CI (and in `scripts/pre-deploy`);
new findings fail it. The one accepted finding — a low-confidence `File.read!` on a trusted
admin/seed path (`Results.Ingest.sync_from_file/1`) — is suppressed with an **inline
`# sobelow_skip ["Traversal.FileModule"]`** comment at the call site, not a `.sobelow-skips`
fingerprint. (The fingerprint baseline is line-keyed, so it silently went stale and failed the
gate whenever an edit shifted the finding's line; the inline skip is bound to the function and
can't drift. `.sobelow-skips` is now empty.) The earlier CSP finding was fixed in `y58` (strict
hash-based CSP), not skipped.

### Before tagging a release: `scripts/pre-deploy`

Run `scripts/pre-deploy` before `git tag vX.Y.Z`. It's the deploy-boundary half of the gate:
`mix precommit` + `mix sobelow` + a local **Docker image build** + a **release-boot smoke
test** (`bin/predictex eval`, with dummy secrets — it doesn't start the endpoint or hit the
DB). This catches a broken image or a release that won't boot on your machine, instead of
after a tag burns a full build/deploy CI cycle. (`docker-compose.prod.yml` lives on the
server, not the repo, so compose-config validation isn't part of the local script.)

### The pre-commit gate (jidoka — no local↔remote seam)

Every commit that stages Elixir files runs `mix precommit`, so a change that would fail CI
fails locally first. `mix precommit` (mix.exs) is the single source for that check list, and
CI's Quality job runs the same commands — keep them in lockstep. The gate is `lefthook run
pre-commit` (scoped by a `*.{ex,exs}` glob in `lefthook.yml`, so docs/beads-only commits
stay fast).

- **Wiring:** beads owns `core.hooksPath` (`.beads/hooks`), so the gate is invoked from the
  committed `.beads/hooks/pre-commit` (a block *outside* the beads markers, which `bd hooks
  install` preserves). It runs automatically once beads hooks are active — no separate
  `lefthook install`. Requirements per checkout: the `lefthook` binary on PATH, and beads
  hooks installed (`bd hooks install`, which sets `core.hooksPath`). If `lefthook` is absent
  the block no-ops (install it to restore the gate).
- **Never `git commit --no-verify`.** Bypassing the gate is a process defect, not a shortcut —
  it relocates the failure to CI. A Claude Code PreToolUse hook (`scripts/guard-no-verify.py`,
  wired in `.claude/settings.json`) blocks the agent from doing it — it tokenizes the command
  (shlex) so quoted flags, `-nm`-style clusters, `bash -c` subshells, and `-c core.hooksPath`
  are all caught, while flags merely named inside a commit message are not.
- **If CI catches something the gate missed, fix the gate first** (add the check to `precommit`),
  then fix the bug — every recurring failure class earns a permanent check.

See `docs/engineering-principles.md` (§1, §5) and `docs/software-delivery-principles.md` (§4, §5).

## Architecture Overview

Phoenix LiveView app (Phoenix 1.8 / LiveView 1.2). The web layer lives in
`lib/predictex_web/` — LiveViews under `live/`, shared function components under
`components/`.

### Domain layer — namespaces advertise the boundaries

`lib/predictex/` follows a functional-core / imperative-shell split. Modules are
grouped under one-level namespaces so the tree itself signals what's public,
what's a pure core, and what's a read model — don't reintroduce flat siblings
when a family already has a namespace.

- **Contexts** (public API, co-located Ecto schemas): `Accounts`, `Tournament`,
  `Predictions`, `Capture`, `Results`, `Fifa`, `Bracket`, `Replay`. Schemas live
  under the context namespace (e.g. `Tournament.Fixture`), never at the top level.
- **`Scoring.*`** — pure football/scoring cores (no Repo, no Ecto): `Scoring.Engine`
  (the scoring laws — `Engine.score/3`), `Scoring.Ranking` (shared rank fold),
  `Scoring.Leaderboard` (no-DB scorer), `Scoring.Standings` (DB-backed, reuses the
  same laws; `+ Standings.Snapshot`), `Scoring.GroupTables` (`+ .Row`),
  `Scoring.Knockout`.
- **`LiveScore.*`** — the live-scoring concern: `Predictex.LiveScore` is the bare
  decode+apply contract (the namespace's primary concept, `Ecto`/`Ecto.Query`
  shape — not a peer, so it stays unprefixed); `LiveScore.Updater` (snapshot
  subscriber) and `LiveScore.Buzz` (live what-if narratives) are its satellites.
- **Read models** feeding LiveViews stay top-level (`Dashboard`, `MatchRecap`) —
  presentation read models, not contexts, so no namespace bucket.

The `test/` tree mirrors `lib/` (test module names match paths, e.g.
`Predictex.Scoring.EngineTest`).

### LiveView templates live in co-located `.heex` files

Render templates are kept **out of the LiveView modules** in co-located `.heex`
files (not inline `~H` sigils) to keep module sizes manageable. Two shapes:

- **Implicit (the default):** the module defines **no** `render/1`. LiveView 1.2
  auto-loads a co-located template named after the source file
  (`fixture_live.ex` → `fixture_live.html.heex`). Aliases (`Layouts`), the `~p`
  verified-route sigil, module-local function components, and colocated JS hooks
  all resolve because the template is compiled inside the module's context.
- **Explicit (only when `render/1` must compute derived assigns):** keep a thin
  `@impl render/1` that does the prep, then `embed_templates "<name>_body.html"`
  and delegate to the generated `<name>_body/1` function component (backed by
  `<name>_body.html.heex`). Used by `leaderboard_live` and `my_predictions_live`
  — the latter's prep depends on `now` (ticks live), so it can't move to event
  handlers without stale-render risk.

A module's own **function components** (e.g. `import_live`'s `paste_form/1`,
`escape_hatch/1`) keep their inline `~H` — only the main page render is extracted.
`.heex` files are format-checked by the gate (`.formatter.exs` lists `heex` with
the `Phoenix.LiveView.HTMLFormatter` plugin), so run `mix format` after editing
them.

## Conventions & Patterns

### Commit / push / deploy boundary

**Commit autonomously; push and deploy are the user's explicit call.** Once a unit of
work is complete and the gate is green (`mix precommit`), commit it without asking — a
local commit is cheap and reversible. Do **not** `git push`, and do **not** tag-and-push
(which deploys to prod), without an explicit instruction from the user to do so.

- This holds **even at session end**: never auto-push. If a session wraps with unpushed
  commits, commit everything, report clearly that the work is *committed but local*, and
  wait for the user to say "push". Stranded-local is acceptable; an un-asked push is not.
- This **supersedes the beads-managed "Session Completion" block above** (inside
  `<!-- BEGIN BEADS INTEGRATION -->`), whose "PUSH TO REMOTE is MANDATORY / YOU must push"
  steps are auto-generated and cannot be edited in place — per the instruction hierarchy,
  this user-authored convention wins. Treat that block's step 4 as "commit, then await the
  push instruction," not "auto-push."
- `git tag vX.Y.Z && git push origin vX.Y.Z` is a **deploy** (see Deploy in RESUME.md) — a
  second, separate gate beyond a plain push, and always requires explicit go-ahead.
- Trunk-based on `main`. (Worktrees are the exception — per global CLAUDE.md they push
  straight to master autonomously; that autonomy is unchanged.)
