#!/usr/bin/env bash
# Run Claude in the repo workspace and post its stdout as a reply to a
# GitHub conversation surface. Invoked by n8n workflows 08-12 (issue body,
# PR body, PR review summary, discussion, discussion comment).
#
# Conversational only — any git changes Claude makes are discarded. Code
# changes belong in the explicit round-trip workflows (01 / 04 / 05 / 07).
#
# The caller (n8n SSH node) is expected to have run
#   eval "$(n8n-agent-prep <owner/repo>)" || exit $?
# first, so $GH_TOKEN is exported and cwd is the repo workspace. Claude
# can read the code if it wants context for its reply, but the workflow
# never pushes.
#
# Usage:
#   n8n-agent-reply <surface> <prompt-b64> <surface-args...>
#
# Surfaces and their args:
#   issue            <prompt-b64> <issue-num>
#   pr               <prompt-b64> <pr-num>
#   discussion       <prompt-b64> <discussion-node-id>
#   discussion-reply <prompt-b64> <discussion-node-id> <reply-to-comment-node-id>
#
# Output contract (consumed by the calling workflow):
#   CLAUDE_RC=<int>
#   CLAUDE_LOG_TAIL<<__END__ ... __END__
#   REPLY_RC=<int>
#   REPLY_URL=<url or empty>
set +e
set -o pipefail

SURFACE="${1:-}"
PROMPT_B64="${2:-}"

if [ -z "$SURFACE" ] || [ -z "$PROMPT_B64" ]; then
  echo "ERROR: usage: n8n-agent-reply <surface> <prompt-b64> [args]" >&2
  echo "REPLY_RC=2"
  echo "REPLY_URL="
  exit 2
fi

case "$SURFACE" in
  issue|pr)
    REF="${3:-}"
    if [ -z "$REF" ]; then
      echo "ERROR: surface=$SURFACE requires <ref> arg" >&2
      echo "REPLY_RC=2"
      echo "REPLY_URL="
      exit 2
    fi
    ;;
  discussion)
    DISC_ID="${3:-}"
    if [ -z "$DISC_ID" ]; then
      echo "ERROR: surface=discussion requires <discussion-node-id>" >&2
      echo "REPLY_RC=2"
      echo "REPLY_URL="
      exit 2
    fi
    ;;
  discussion-reply)
    DISC_ID="${3:-}"
    REPLY_TO="${4:-}"
    if [ -z "$DISC_ID" ]; then
      echo "ERROR: surface=discussion-reply requires <discussion-node-id> [<reply-to-node-id>]" >&2
      echo "REPLY_RC=2"
      echo "REPLY_URL="
      exit 2
    fi
    ;;
  *)
    echo "ERROR: unknown surface '$SURFACE'" >&2
    echo "REPLY_RC=2"
    echo "REPLY_URL="
    exit 2
    ;;
esac

PROMPT_FILE="/tmp/reply-$$-prompt.txt"
REPLY_FILE="/tmp/reply-$$-body.md"
CLAUDE_LOG="/tmp/reply-$$.log"

cleanup() {
  rm -f "$PROMPT_FILE" "$REPLY_FILE" "$CLAUDE_LOG" "${REPLY_FILE}.cut"
}
trap cleanup EXIT

echo "$PROMPT_B64" | base64 -d > "$PROMPT_FILE"
claude --print --dangerously-skip-permissions < "$PROMPT_FILE" > "$REPLY_FILE" 2>"$CLAUDE_LOG"
CLAUDE_RC=$?
echo "CLAUDE_RC=$CLAUDE_RC"
echo "CLAUDE_LOG_BYTES=$(wc -c < "$CLAUDE_LOG" 2>/dev/null || echo 0)"
echo "CLAUDE_LOG_TAIL<<__END__"
tail -n 20 "$CLAUDE_LOG" 2>/dev/null || true
echo "__END__"

if [ "$CLAUDE_RC" -ne 0 ] || [ ! -s "$REPLY_FILE" ]; then
  echo "REPLY_RC=$CLAUDE_RC"
  echo "REPLY_URL="
  exit 0
fi

# Discard any code changes — this surface is conversational only. Surfacing
# the count here is just for log visibility.
DIRTY=$(git -C . status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo 0)
if [ "${DIRTY:-0}" != "0" ]; then
  echo "DISCARDED_CHANGES=$DIRTY"
  git -C . reset --hard HEAD >/dev/null 2>&1 || true
  git -C . clean -fd >/dev/null 2>&1 || true
fi

# Cap reply body so a runaway response can't dump the whole repo into a
# comment. GitHub's hard limit is 65536 chars; leave headroom for the
# truncation footer.
MAX_BYTES=60000
if [ "$(wc -c < "$REPLY_FILE")" -gt "$MAX_BYTES" ]; then
  head -c "$MAX_BYTES" "$REPLY_FILE" > "${REPLY_FILE}.cut"
  printf '\n\n_(reply truncated at %d bytes by n8n-agent-reply)_\n' "$MAX_BYTES" >> "${REPLY_FILE}.cut"
  mv "${REPLY_FILE}.cut" "$REPLY_FILE"
fi

post_via_gh() {
  local kind="$1" ref="$2" out rc url
  out=$(gh "$kind" comment "$ref" --body-file "$REPLY_FILE" 2>&1)
  rc=$?
  echo "REPLY_RC=$rc"
  url=$(printf '%s\n' "$out" | grep -Eo 'https://github.com/[^ ]+#issuecomment-[0-9]+' | tail -1)
  if [ -z "$url" ]; then
    # gh prints the comment URL on success; if missing, fall back to the
    # plain html URL which appears on first line of stdout.
    url=$(printf '%s\n' "$out" | grep -Eo 'https://github.com/[^ ]+' | tail -1)
  fi
  echo "REPLY_URL=$url"
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | sed 's/^/  gh: /' >&2
  fi
}

post_via_graphql() {
  local query out rc url body_json
  body_json=$(jq -Rs . < "$REPLY_FILE")
  if [ -n "${REPLY_TO:-}" ]; then
    query=$(jq -nc --arg disc "$DISC_ID" --arg reply "$REPLY_TO" --argjson body "$body_json" '{
      query: "mutation($disc: ID!, $reply: ID!, $body: String!) { addDiscussionComment(input: { discussionId: $disc, replyToId: $reply, body: $body }) { comment { url } } }",
      variables: { disc: $disc, reply: $reply, body: $body }
    }')
  else
    query=$(jq -nc --arg disc "$DISC_ID" --argjson body "$body_json" '{
      query: "mutation($disc: ID!, $body: String!) { addDiscussionComment(input: { discussionId: $disc, body: $body }) { comment { url } } }",
      variables: { disc: $disc, body: $body }
    }')
  fi
  out=$(printf '%s' "$query" | gh api graphql --input - 2>&1)
  rc=$?
  echo "REPLY_RC=$rc"
  url=$(printf '%s\n' "$out" | jq -r '.data.addDiscussionComment.comment.url // empty' 2>/dev/null || true)
  echo "REPLY_URL=$url"
  if [ "$rc" -ne 0 ] || [ -z "$url" ]; then
    printf '%s\n' "$out" | sed 's/^/  gql: /' >&2
  fi
}

case "$SURFACE" in
  issue) post_via_gh issue "$REF" ;;
  pr)    post_via_gh pr    "$REF" ;;
  discussion|discussion-reply) post_via_graphql ;;
esac

exit 0
