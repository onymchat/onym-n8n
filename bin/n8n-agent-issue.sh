#!/usr/bin/env bash
# Run Claude on a fresh worktree for a GitHub issue and open a PR.
#
# Invoked indirectly by n8n workflows 01 and 07 — the manager dispatcher
# (n8n-manager-dispatch) SSHes from manager-agent to the chosen
# employee and runs this script. The dispatcher already exported
# GH_TOKEN via n8n-agent-prep — see build_remote_cmd() in the
# dispatcher for the wrapper.
#
# Args:
#   $1 = issue number
#   $2 = prompt (base64)
#   $3 = reviewer login (may be empty)
#
# Output contract (consumed by the workflow's "Comment on issue" step):
#   CLAUDE_RC=<int>
#   PUSH_RC=<int>
#   GH_RC=<int>
#   PR_URL=<url or empty>
set +e
set -o pipefail

ISSUE="$1"
PROMPT_B64="$2"
REVIEWER="$3"

if [ -z "$ISSUE" ] || [ -z "$PROMPT_B64" ]; then
  echo "ERROR: n8n-agent-issue.sh requires issue number and prompt" >&2
  echo "PR_URL="
  exit 2
fi

# cwd is the per-repo workspace established by n8n-agent-prep
# (~/workspaces/<owner>__<repo>); worktrees go in a sibling dir so they
# stay scoped to that repo.
PRIMARY="$PWD"
WT_ROOT="${PRIMARY}-worktrees"
WT_DIR="$WT_ROOT/issue-$ISSUE"
BRANCH="agent/issue-$ISSUE"
PROMPT_FILE="/tmp/prompt-issue-$ISSUE.txt"

cleanup() {
  cd "$PRIMARY" 2>/dev/null || return
  git worktree remove --force "$WT_DIR" >/dev/null 2>&1 || rm -rf "$WT_DIR" 2>/dev/null
  git worktree prune >/dev/null 2>&1
}

if [ ! -d "$PRIMARY/.git" ]; then
  echo "ERROR: $PRIMARY is not a git repository — caller must run \`eval \"\$(n8n-agent-prep <owner/repo>)\"\` first" >&2
  echo "PR_URL="
  exit 10
fi

# Idempotency: GitHub fires several events per issue (opened, labeled,
# assigned) and the workflow filter accepts all of them, so the same issue
# can trigger this script multiple times. If a PR for this branch is
# already open, skip the whole run (no Claude, no push, no extra comment).
EXISTING=$(gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url' 2>&1)
if [ -n "$EXISTING" ] && [ "${EXISTING#https://}" != "$EXISTING" ]; then
  echo "SKIPPED=existing-pr"
  echo "PR_URL=$EXISTING"
  exit 0
fi

mkdir -p "$WT_ROOT"
git worktree prune >/dev/null 2>&1
if [ -d "$WT_DIR" ]; then
  git worktree remove --force "$WT_DIR" >/dev/null 2>&1 || rm -rf "$WT_DIR"
fi
# Evict any OTHER worktree that has $BRANCH checked out — otherwise
# `worktree add -B` refuses to reset a branch held elsewhere.
CONFLICT_WT=$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$BRANCH" -v me="$WT_DIR" '
  /^worktree / { wt=$2 }
  /^branch / && $2==b && wt!=me { print wt; exit }
')
if [ -n "$CONFLICT_WT" ] && [ "$CONFLICT_WT" != "$PRIMARY" ]; then
  git worktree remove --force "$CONFLICT_WT" >/dev/null 2>&1 || rm -rf "$CONFLICT_WT"
  git worktree prune >/dev/null 2>&1
fi
# Stale branch from a prior failed run would block `worktree add -B`.
git branch -D "$BRANCH" >/dev/null 2>&1
GIT_ERR="/tmp/git-wt-err-$$"
if ! git worktree add -B "$BRANCH" "$WT_DIR" origin/main >/dev/null 2>"$GIT_ERR"; then
  echo "ERROR: could not create worktree $WT_DIR" >&2
  sed 's/^/  git: /' "$GIT_ERR" >&2
  rm -f "$GIT_ERR"
  echo "PR_URL="
  exit 11
fi
rm -f "$GIT_ERR"

cd "$WT_DIR" || { cleanup; echo "PR_URL="; exit 12; }

CLAUDE_LOG="/tmp/claude-issue-$ISSUE.log"
echo "$PROMPT_B64" | base64 -d > "$PROMPT_FILE"
claude --print --dangerously-skip-permissions < "$PROMPT_FILE" > "$CLAUDE_LOG" 2>&1
CLAUDE_RC=$?
rm -f "$PROMPT_FILE"
echo "CLAUDE_RC=$CLAUDE_RC"
echo "CLAUDE_LOG_BYTES=$(wc -c < "$CLAUDE_LOG" 2>/dev/null || echo 0)"
echo "CLAUDE_LOG_TAIL<<__END__"
tail -n 40 "$CLAUDE_LOG" 2>/dev/null || true
echo "__END__"
# (don't rm $CLAUDE_LOG yet — needed below for the conversational-reply
# fallback when claude declines to make code changes)

# Auto-commit any working-tree edits Claude left behind. Common failure
# mode: claude prints a confident "I edited files X/Y/Z" summary but
# forgot the final `git commit`, leaving HEAD == origin/main. We'd
# rather salvage the work than throw it away.
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [ "${DIRTY:-0}" != "0" ]; then
  echo "AUTO_COMMITTED=$DIRTY"
  git add -A
  git -c commit.gpgsign=false commit -m "agent: implement issue #$ISSUE" >/dev/null 2>&1 || true
fi

if git diff --quiet origin/main..HEAD; then
  echo "PR_URL="
  if [ "${DIRTY:-0}" != "0" ]; then
    # Edits existed but the commit landed empty — shouldn't happen, but
    # surface it explicitly instead of conflating with the no-edits case.
    echo "ERROR: claude edited files but the auto-commit produced no diff" >&2
  elif [ -s "$CLAUDE_LOG" ]; then
    # Claude made no code changes — typically a conversational reply
    # (pushback on the spec, clarifying question, declining to
    # implement). Post it as a comment on the issue from the employee's
    # own gh account so the human who summoned the bot sees the reply.
    # Without this, the response vanished into the n8n execution log.
    REPLY_OUT=$(gh issue comment "$ISSUE" --body-file "$CLAUDE_LOG" 2>&1)
    REPLY_RC=$?
    REPLY_URL=$(printf '%s\n' "$REPLY_OUT" | grep -Eo 'https://github.com/[^ ]+#issuecomment-[0-9]+' | tail -1)
    echo "REPLY_RC=$REPLY_RC"
    echo "REPLY_URL=$REPLY_URL"
    if [ "$REPLY_RC" -ne 0 ]; then
      echo "REPLY_ERR<<__END__" >&2
      printf '%s\n' "$REPLY_OUT" >&2
      echo "__END__" >&2
    fi
  else
    echo "ERROR: claude made no edits and produced no log" >&2
  fi
  rm -f "$CLAUDE_LOG"
  cleanup
  exit 0
fi
rm -f "$CLAUDE_LOG"

git push -u origin "$BRANCH" --force 2>&1
PUSH_RC=$?
echo "PUSH_RC=$PUSH_RC"
if [ "$PUSH_RC" -ne 0 ]; then
  echo "PR_URL="
  cleanup
  exit 0
fi

EXISTING=$(gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url' 2>&1)
if [ -n "$EXISTING" ] && [ "${EXISTING#https://}" != "$EXISTING" ]; then
  # Another concurrent run raced us to PR creation. Don't double-comment.
  echo "SKIPPED=reused-pr"
  echo "PR_URL=$EXISTING"
  cleanup
  exit 0
fi

if [ -n "$REVIEWER" ]; then
  GH_OUT=$(gh pr create --fill --base main --head "$BRANCH" \
             --reviewer "$REVIEWER" 2>&1)
else
  GH_OUT=$(gh pr create --fill --base main --head "$BRANCH" 2>&1)
fi
GH_RC=$?
echo "GH_RC=$GH_RC"
echo "GH_OUT<<__END__"
echo "$GH_OUT"
echo "__END__"
PR_URL=$(printf '%s\n' "$GH_OUT" | grep -Eo 'https://github.com/[^ ]+/pull/[0-9]+' | tail -1)
echo "PR_URL=$PR_URL"

cleanup
exit 0
