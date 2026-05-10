#!/usr/bin/env bash
# Run Claude in a worktree to address a PR review comment, push if it made
# changes. Invoked by n8n workflow 05-pr-address-comment.
#
# Args:
#   $1 = PR number
#   $2 = PR branch (head ref)
#   $3 = triggering comment id (used to namespace the worktree / prompt)
#   $4 = prompt (base64)
#
# Output contract (consumed downstream):
#   CLAUDE_RC=<int>
#   NO_CHANGES=1        (if claude produced no diff)
#   PUSH_RC=<int>
#   NEW_SHA=<sha>
set +e
set -o pipefail

PR="$1"
BRANCH="$2"
CID="$3"
PROMPT_B64="$4"

if [ -z "$PR" ] || [ -z "$BRANCH" ] || [ -z "$PROMPT_B64" ]; then
  echo "ERROR: n8n-agent-address.sh requires PR, branch, and prompt" >&2
  exit 2
fi

# cwd is the per-repo workspace established by n8n-agent-prep
# (~/workspaces/<owner>__<repo>); worktrees go in a sibling dir so they
# stay scoped to that repo.
PRIMARY="$PWD"
WT_ROOT="${PRIMARY}-worktrees"
WT_DIR="$WT_ROOT/pr-$PR-comment-$CID"
PROMPT_FILE="/tmp/fix-$PR-$CID.txt"

cleanup() {
  cd "$PRIMARY" 2>/dev/null || return
  git worktree remove --force "$WT_DIR" >/dev/null 2>&1 || rm -rf "$WT_DIR" 2>/dev/null
  git worktree prune >/dev/null 2>&1
}

if [ ! -d "$PRIMARY/.git" ]; then
  echo "ERROR: $PRIMARY is not a git repository — caller must run \`eval \"\$(n8n-agent-prep <owner/repo>)\"\` first" >&2
  exit 10
fi

git fetch origin "$BRANCH" 2>&1

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
git branch -D "$BRANCH" >/dev/null 2>&1
GIT_ERR="/tmp/git-wt-err-$$"
if ! git worktree add -B "$BRANCH" "$WT_DIR" "origin/$BRANCH" >/dev/null 2>"$GIT_ERR"; then
  echo "ERROR: could not create worktree $WT_DIR for $BRANCH" >&2
  sed 's/^/  git: /' "$GIT_ERR" >&2
  rm -f "$GIT_ERR"
  exit 11
fi
rm -f "$GIT_ERR"

cd "$WT_DIR" || { cleanup; exit 12; }

CLAUDE_LOG="/tmp/claude-fix-$PR-$CID.log"
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
# fallback when claude declines to push code changes)

# Auto-commit any uncommitted edits. Without this, claude editing files
# but skipping `git commit` looks indistinguishable from claude doing
# nothing — both leave HEAD unchanged.
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [ "${DIRTY:-0}" != "0" ]; then
  echo "AUTO_COMMITTED=$DIRTY"
  git add -A
  git -c commit.gpgsign=false commit -m "address review comment $CID" >/dev/null 2>&1 || true
fi

if git diff --quiet "origin/$BRANCH..HEAD"; then
  echo "NO_CHANGES=1"
  if [ "${DIRTY:-0}" != "0" ]; then
    echo "ERROR: claude edited files but the auto-commit produced no diff" >&2
  elif [ -s "$CLAUDE_LOG" ]; then
    # Claude made no code changes — typically a conversational reply
    # (clarifying question, pushback on the review comment, etc.).
    # Post it as a comment on the PR from the employee's own gh
    # account so the reviewer sees the response.
    REPLY_OUT=$(gh pr comment "$PR" --body-file "$CLAUDE_LOG" 2>&1)
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

git push origin "HEAD:$BRANCH" 2>&1
PUSH_RC=$?
echo "PUSH_RC=$PUSH_RC"
NEW_SHA=$(git rev-parse HEAD)
echo "NEW_SHA=$NEW_SHA"

cleanup
exit 0
