#!/bin/bash
# Per-container first-run, executed as the `agent` user on every boot.
# Idempotent: generates SSH keypairs, seeds authorized_keys, persists
# GITHUB_TOKEN, and (for the manager) sets up the fan-out SSH key it
# uses to reach employees.
#
# ROLE branches:
#   manager   — accepts inbound SSH from n8n; outbound SSH to all
#               employees via a dedicated keypair (manager-fanout).
#   employee  — accepts inbound SSH from the manager only.
set -euo pipefail

cd "$HOME"
mkdir -p .ssh workspace workspaces .config/gh
chmod 700 .ssh

# Per-container host→host SSH key (container → mac-host forced command,
# or any other upstream the container needs to reach as itself).
if [ ! -f .ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -f .ssh/id_ed25519 \
        -C "${ROLE:-unknown}-${EMPLOYEE_LOGIN:-${HOSTNAME}}@$(hostname)"
fi

# Manager-only: dedicated key for fanning out to employees. Kept separate
# from id_ed25519 so the manager-fanout key never grants any other access.
if [ "${ROLE:-}" = "manager" ] && [ ! -f .ssh/manager-fanout ]; then
    ssh-keygen -t ed25519 -N "" -f .ssh/manager-fanout \
        -C "manager-fanout@$(hostname)"
fi

# Authorise inbound SSH keys.
#   ROLE=manager:  trust n8n (N8N_SSH_PUBKEY) + admin if set
#   ROLE=employee: trust the manager (MANAGER_SSH_PUBKEY) + admin if set
touch .ssh/authorized_keys
chmod 600 .ssh/authorized_keys
case "${ROLE:-}" in
  manager)  TRUST_VARS="ADMIN_SSH_PUBKEY N8N_SSH_PUBKEY" ;;
  employee) TRUST_VARS="ADMIN_SSH_PUBKEY MANAGER_SSH_PUBKEY" ;;
  *)        TRUST_VARS="ADMIN_SSH_PUBKEY N8N_SSH_PUBKEY MANAGER_SSH_PUBKEY" ;;
esac
for _var in $TRUST_VARS; do
    _val="${!_var:-}"
    if [ -n "$_val" ] && ! grep -qxF "$_val" .ssh/authorized_keys; then
        echo "$_val" >> .ssh/authorized_keys
    fi
done
unset _var _val

# Persist the bot's GitHub token for n8n-agent-prep / the manager
# dispatcher to clone arbitrary repos on demand. ~/.gh-token is the
# single source of truth from here on — env-var GITHUB_TOKEN may be
# absent on later boots (env_file is `required: false`) but the volume-
# backed file survives, so downstream scripts read from the file.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    umask 077
    printf '%s' "$GITHUB_TOKEN" > "$HOME/.gh-token"
fi

# Optional: pin a single workspace clone for back-compat with the legacy
# single-repo flow.
if [ -s "$HOME/.gh-token" ] && [ -n "${GITHUB_REPO:-}" ]; then
    TOKEN=$(cat "$HOME/.gh-token")
    if [ ! -d workspace/.git ]; then
        git clone "https://x-access-token:${TOKEN}@github.com/${GITHUB_REPO}.git" workspace
    else
        git -C workspace remote set-url origin \
            "https://x-access-token:${TOKEN}@github.com/${GITHUB_REPO}.git"
    fi
    unset TOKEN
fi

# gh auth + git credential helper so push/fetch don't require the token
# in the URL. Read from ~/.gh-token (not $GITHUB_TOKEN) so this still
# runs on boots where the env var was dropped, as long as the file from
# a prior boot is intact. `gh auth login --with-token` reads from stdin
# — `--with-token` + setting GH_TOKEN env is a no-op gotcha that hangs.
if [ -s "$HOME/.gh-token" ]; then
    if ! gh auth login --with-token --hostname github.com < "$HOME/.gh-token"; then
        echo "WARN: gh auth login failed — token may be invalid/expired" >&2
    fi
    gh auth setup-git || true
fi

# Claude Code: bypass all permission prompts. Each agent runs in its own
# hardened, non-root, network-isolated container — the container is the
# security boundary, so per-tool prompts add no protection and just stall
# headless `claude --print` calls (no TTY to answer them).
mkdir -p .claude
cat > .claude/settings.json <<'JSON'
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "skipDangerousModePermissionPrompt": true
  }
}
JSON
chmod 600 .claude/settings.json

# Sensible git identity. Per-employee env files set GIT_COMMITTER_NAME /
# GIT_COMMITTER_EMAIL to the bot's GitHub login.
DEFAULT_NAME="${EMPLOYEE_GITHUB_LOGIN:-${ROLE:-agent}}"
git config --global user.name  "${GIT_COMMITTER_NAME:-$DEFAULT_NAME}"
git config --global user.email "${GIT_COMMITTER_EMAIL:-${DEFAULT_NAME}@onym-n8n.local}"
git config --global init.defaultBranch main
git config --global pull.rebase true

# Announce per-container pubkeys so the operator can authorise them
# upstream. The manager prints BOTH its own id_ed25519 (for any host-side
# auth it needs) AND its manager-fanout pubkey (which must land in every
# employee's MANAGER_SSH_PUBKEY env var).
echo "=== $(hostname) (${ROLE:-?}) public key ==="
cat .ssh/id_ed25519.pub
echo "=== end pubkey ==="

if [ "${ROLE:-}" = "manager" ] && [ -f .ssh/manager-fanout.pub ]; then
    echo "=== $(hostname) MANAGER_SSH_PUBKEY (paste into each employees/<login>.env) ==="
    cat .ssh/manager-fanout.pub
    echo "=== end MANAGER_SSH_PUBKEY ==="
fi
