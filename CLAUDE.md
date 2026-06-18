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
                   # format --check-formatted, test — the SAME checks CI's Quality job runs
```

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
  it relocates the failure to CI. A Claude Code PreToolUse hook (`scripts/guard-no-verify.sh`,
  wired in `.claude/settings.json`) blocks the agent from doing it.
- **If CI catches something the gate missed, fix the gate first** (add the check to `precommit`),
  then fix the bug — every recurring failure class earns a permanent check.

See `docs/engineering-principles.md` (§1, §5) and `docs/software-delivery-principles.md` (§4, §5).

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_
