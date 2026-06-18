#!/usr/bin/env bash
# predictex-unx — block `git commit --no-verify` / `-n` from the agent.
#
# The pre-commit gate (mix precommit, via lefthook) is the single jidoka enforcement
# point; bypassing it relocates failures to CI where they are costlier to find. This is
# a Claude Code PreToolUse(Bash) hook: it reads the tool-call JSON on stdin and exits 2
# to block the call (exit 0 allows it).
set -euo pipefail

cmd="$(jq -r '.tool_input.command // ""' 2>/dev/null || true)"

# Strip single- and double-quoted substrings first, so a commit *message* that merely
# mentions "--no-verify" isn't mistaken for the actual flag — only unquoted CLI tokens
# are inspected.
flags="$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")"

if printf '%s' "$flags" | grep -Eq 'git[[:space:]]+commit' \
  && printf '%s' "$flags" | grep -Eqi -- '(--no-verify|[[:space:]]-n([[:space:]]|$))'; then
  {
    echo "BLOCKED: 'git commit --no-verify' bypasses the pre-commit gate (mix precommit)."
    echo "The gate runs the same checks as CI — fix the failing check, do not skip it."
  } >&2
  exit 2
fi
exit 0
