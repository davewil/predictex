#!/usr/bin/env bash
#
# Copy the homelab-shared deploy secrets from Vaultwarden into the predictex
# GitHub Actions secrets. Run it in a real terminal (the master-password prompt
# needs a TTY):
#
#   ./scripts/sync-secrets-from-vault.sh list   # show matching vault items
#   ./scripts/sync-secrets-from-vault.sh         # copy the secrets to GitHub
#
# Each vault item is named exactly after its GitHub secret; the value is read from
# the item's password, notes, or SSH-key field (whichever is present). Values are
# piped straight into `gh secret set` via stdin — never printed, never in argv.
# SECRET_KEY_BASE and POSTGRES_PASSWORD are already set, so this handles the four
# homelab-shared secrets only.
#
set -euo pipefail

REPO="davewil/predictex"
SECRETS="DEPLOY_HOST DEPLOY_SSH_KEY TS_OAUTH_CLIENT_ID TAILSCALE_AUTHKEY"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' not installed"; exit 1; }; }
need bw
need gh
need jq

# Resolve a vault item's value: password field, else notes, else SSH-key private key.
fetch_secret() {
  local item="$1" v
  v="$(bw get password "$item" 2>/dev/null || true)"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(bw get notes "$item" 2>/dev/null || true)"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  v="$(bw get item "$item" 2>/dev/null | jq -r '.sshKey.privateKey // empty' 2>/dev/null || true)"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  return 1
}

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
  # stale login `bw unlock` exits non-zero (after printing a 401 to stderr).
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

# `list` mode: show items whose name matches a secret (or related keyword).
if [ "${1:-}" = "list" ]; then
  unlock
  echo
  echo "Vault items (name [type] — username):"
  for kw in $SECRETS DEPLOY TAILSCALE TS_OAUTH OAUTH tailscale deploy ssh host homelab docker; do
    bw list items --search "$kw" \
      | jq -r '.[] | "  \(.name) [\(.type)] — \(.login.username // "")"'
  done | sort -u
  bw lock >/dev/null 2>&1 || true
  echo
  echo "Item types: 1=login  2=secure note  4=SSH key. Re-run without 'list' to copy."
  exit 0
fi

unlock
trap 'bw lock >/dev/null 2>&1 || true; unset BW_SESSION' EXIT

ok=0
missing=0
for name in $SECRETS; do
  printf 'Fetching %s... ' "$name"
  if value="$(fetch_secret "$name")" && [ -n "$value" ]; then
    printf '%s' "$value" | gh secret set "$name" -R "$REPO" >/dev/null
    echo "set ✓"
    ok=$((ok + 1))
  else
    echo "NOT FOUND — no vault item named '$name' with a readable value"
    missing=$((missing + 1))
  fi
done

echo
echo "Done: $ok set, $missing missing."
echo "Repo secrets now on $REPO:"
gh secret list -R "$REPO"
