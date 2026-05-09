#!/usr/bin/env bash
# Serialize an n8n-agent-* invocation behind a per-branch flock so two
# concurrent webhooks targeting the same employee + branch queue rather
# than fight over the same worktree. Used by the manager dispatcher's
# build_remote_cmd() — every surface wraps its `exec n8n-agent-*` with
# this. The lock is exclusive, blocking, and auto-released on process
# exit (file descriptor close), so no cleanup is needed even on SIGKILL.
#
# Why this exists: n8n-agent-issue.sh / n8n-agent-address.sh used to
# force-remove any other worktree holding the target branch (so a second
# webhook for the same issue/PR would yank the worktree out from under
# the still-running first webhook). With this wrapper, two concurrent
# requests for the same branch run in series; different branches still
# run in parallel.
#
# Trade-off: long Claude runs hold the SSH socket open for the queue
# wait. n8n's SSH node timeout must be ≥ the worst-case queued duration
# (rule of thumb: depth × per-run budget).
#
# Usage:
#   n8n-agent-lock <key> -- <cmd> [args...]
#
# <key> may contain slashes (branch names like agent/issue-42); they're
# rewritten to "__" so the lock file path is flat under ~/.locks.
set -euo pipefail

KEY="${1:?usage: n8n-agent-lock <key> -- <cmd> [args...]}"
shift
if [ "${1:-}" = "--" ]; then
  shift
fi
if [ "$#" -eq 0 ]; then
  echo "ERROR: n8n-agent-lock: missing command after key" >&2
  exit 2
fi

LOCK_DIR="$HOME/.locks"
mkdir -p "$LOCK_DIR"

SAFE_KEY="${KEY//\//__}"
LOCK_FILE="$LOCK_DIR/${SAFE_KEY}.lock"

exec flock -x "$LOCK_FILE" "$@"
