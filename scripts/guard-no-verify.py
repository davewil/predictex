#!/usr/bin/env python3
"""predictex-unx — block the agent from bypassing the pre-commit gate.

Claude Code PreToolUse(Bash) hook. Reads the tool-call JSON on stdin; exit 2 blocks the
call, exit 0 allows it. Detects a `git commit` that bypasses the gate via `--no-verify` /
`-n` (any short-flag cluster, e.g. -nm/-vn), quoted flags (`git commit "--no-verify"`),
one level of subshell wrapper (`bash -c "git commit --no-verify"`), or hook-disabling
(`git -c core.hooksPath=... commit`).

Uses real shell tokenization (shlex) so the guard sees the same argv the shell will — we do
NOT pre-strip quoted text (a quoted flag still reaches git), and we scan each git statement's
argv with statement boundaries so:
  - a flag named inside an `-m` message is that flag's value token, never matched;
  - compound commands (`git add . && git commit --no-verify`, multi-line scripts) are each
    inspected, not just the first `git`;
  - `core.hooksPath` is flagged only as a real `-c`/config value, not as message text.

Threat model: a DEV GUARDRAIL against the agent casually/commonly bypassing the gate, not a
boundary against a determined adversary (who can edit this hook, use plumbing, etc.). It fails
CLOSED when a git commit is present but unparseable, and OPEN on input that is unparseable AND
does not look like a commit — blocking every unrelated Bash call on a guard glitch is a worse
failure than missing an exotic evasion.
"""
import json
import re
import sys
import shlex

# Options whose FOLLOWING token is a value (so it is not treated as a flag).
VALUE_FLAGS = {
    "-m", "--message", "-F", "--file", "-c", "--reedit-message",
    "-C", "--reuse-message", "--author", "--date", "--cleanup", "-S", "--gpg-sign",
}
# git's own pre-subcommand options that consume a value (`git -c k=v commit`).
GIT_VALUE_OPTS = {"-c", "-C", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
OPERATORS = {";", "&&", "||", "|", "|&", "&", "\n"}
SHORT_CLUSTER_WITH_N = re.compile(r"^-[A-Za-z]*n[A-Za-z]*$")
SUBSHELL_WRAPPERS = {"bash", "sh", "zsh", "dash", "ksh", "eval", "env",
                     "xargs", "nohup", "timeout", "command", "stdbuf"}


def is_bypass_flag(tok):
    return tok == "--no-verify" or tok.startswith("--no-verify=") or bool(
        SHORT_CLUSTER_WITH_N.match(tok)
    )


def scan_tokens(tokens):
    """True if any `git commit` statement in this flat token stream bypasses the gate."""
    i, n = 0, len(tokens)
    while i < n:
        if tokens[i] != "git":
            i += 1
            continue
        i += 1
        hookpath = False
        # git's own options, up to the subcommand or a statement boundary
        while i < n and tokens[i] not in OPERATORS:
            t = tokens[i]
            if t in GIT_VALUE_OPTS:
                if i + 1 < n and "core.hookspath" in tokens[i + 1].lower():
                    hookpath = True
                i += 2
                continue
            if t.startswith("-"):
                if "core.hookspath" in t.lower():
                    hookpath = True
                i += 1
                continue
            break
        if i >= n or tokens[i] in OPERATORS:
            continue
        subcmd = tokens[i]
        i += 1
        if subcmd != "commit":
            continue
        # scan commit args until the next statement boundary or git invocation
        skip = False
        while i < n and tokens[i] not in OPERATORS and tokens[i] != "git":
            t = tokens[i]
            if skip:
                skip = False
            elif t in VALUE_FLAGS:
                skip = True
            elif t.startswith(("-m", "-F")) and len(t) > 2 and not t.startswith("--"):
                pass  # attached value form: -mMSG / -Ffile
            elif t.startswith(("--message=", "--file=", "--author=", "--date=")):
                pass
            elif is_bypass_flag(t):
                return True
            i += 1
        if hookpath:
            return True
    return False


def detect(cmd_str, depth=0):
    if depth > 3 or not cmd_str:
        return False
    try:
        tokens = shlex.split(cmd_str, posix=True)
    except ValueError:
        # unbalanced quotes etc. — fail CLOSED only if it smells like a no-verify commit
        low = cmd_str.lower()
        return "commit" in low and ("--no-verify" in low or "core.hookspath" in low)

    # recurse into subshell wrapper bodies (bash -c "git commit --no-verify", etc.)
    if tokens and tokens[0].split("/")[-1] in SUBSHELL_WRAPPERS:
        for t in tokens[1:]:
            if "commit" in t and detect(t, depth + 1):
                return True

    return scan_tokens(tokens)


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = (payload.get("tool_input") or {}).get("command") or ""
    except Exception:
        return 0  # malformed payload — do not brick unrelated Bash on a parser hiccup

    if detect(cmd):
        sys.stderr.write(
            "BLOCKED: this skips the pre-commit gate (mix precommit). The gate runs the "
            "same checks as CI — fix the failing check, do not bypass it.\n"
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
