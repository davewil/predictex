#!/usr/bin/env bash
#
# Copy the homelab-shared deploy secrets from Vaultwarden into the predictex
# GitHub Actions secrets. Run it in a real terminal (the master-password prompt
# needs a TTY):
#
#   ./scripts/sync-secrets-from-vault.sh list   # discover your vault item names
#   ./scripts/sync-secrets-from-vault.sh         # copy the secrets to GitHub
#
# Values are piped straight into `gh secret set` via stdin — never printed, never
# placed on the command line. SECRET_KEY_BASE and POSTGRES_PASSWORD are already set
# (generated), so this only handles the four homelab-shared ones.
#
set -euo pipefail

REPO="davewil/predictex"

# ---------------------------------------------------------------------------
# EDIT THESE to match your Vaultwarden items. Each function must echo the value.
# Common forms:
#   bw get username "Item Name"           # the login username field
#   bw get password "Item Name"           # the login password field
#   bw get notes    "Item Name"           # the notes field (good for multi-line keys)
#   bw get item "Item Name" | jq -r '.sshKey.privateKey'   # a Bitwarden SSH-key item
#   bw get item "Item Name" | jq -r '.fields[] | select(.name=="host").value'  # custom field
# Run the `list` mode first to find the exact item names.
# ---------------------------------------------------------------------------
get_DEPLOY_HOST()        { bw get username "Homelab Docker Host"; }
get_DEPLOY_SSH_KEY()     { bw get notes    "Homelab Deploy SSH Key"; }
get_TS_OAUTH_CLIENT_ID() { bw get username "Tailscale CI OAuth"; }
get_TAILSCALE_AUTHKEY()  { bw get password "Tailscale CI OAuth"; }
# ---------------------------------------------------------------------------

SECRETS="DEPLOY_HOST DEPLOY_SSH_KEY TS_OAUTH_CLIENT_ID TAILSCALE_AUTHKEY"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not installed"; exit 1; }; }
need bw
need gh
need jq

unlock() {
  local status
  status="$(bw status 2>/dev/null | jq -r '.status')"
  if [ "$status" = "unauthenticated" ]; then
    echo "error: not logged in. Run: bw login" >&2
    exit 1
  fi

  echo "Unlocking Vaultwarden ($(bw status 2>/dev/null | jq -r '.serverUrl'))..." >&2

  # IMPORTANT: bw writes the "Master password:" prompt to stderr. Do NOT redirect
  # it — otherwise the prompt vanishes and the script just appears to hang. On a
  # stale login `bw unlock` exits non-zero (after printing a 401 to stderr); we
  # catch the non-zero exit and point at the fix.
  if ! BW_SESSION="$(bw unlock --raw)"; then
    echo >&2
    echo "Unlock failed — your bw login is likely stale (expired refresh token)." >&2
    echo "Re-authenticate, then re-run this script:" >&2
    echo "    bw logout && bw login" >&2
    exit 1
  fi

  export BW_SESSION
  bw sync >/dev/null
}

# `list` mode: print candidate items so you can fill in the getters above.
if [ "${1:-}" = "list" ]; then
  unlock
  echo
  echo "Candidate items (name — username):"
  for kw in tailscale deploy ssh host homelab docker; do
    bw list items --search "$kw" \
      | jq -r '.[] | "  \(.name) — \(.login.username // "(no username)")"'
  done | sort -u
  bw lock >/dev/null 2>&1 || true
  echo
  echo "Edit get_*() in this script to match, then re-run without 'list'."
  exit 0
fi

unlock
trap 'bw lock >/dev/null 2>&1 || true; unset BW_SESSION' EXIT

ok=0
missing=0
for name in $SECRETS; do
  printf 'Fetching %s... ' "$name"
  if value="$("get_$name" 2>/dev/null)" && [ -n "$value" ]; then
    printf '%s' "$value" | gh secret set "$name" -R "$REPO" >/dev/null
    echo "set ✓"
    ok=$((ok + 1))
  else
    echo "NOT FOUND — fix get_${name}() in this script"
    missing=$((missing + 1))
  fi
done

echo
echo "Done: $ok set, $missing missing."
echo "Repo secrets now on $REPO:"
gh secret list -R "$REPO"
