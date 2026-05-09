#!/usr/bin/env bash
# Manager-side request dispatcher. Invoked by n8n via SSH on every workflow
# trigger as the SOLE downstream call — n8n knows nothing about which
# employees exist.
#
# Reads /etc/onym/employees.json (mounted from ../employees.json on the
# host), parses the request, picks the target employee, posts a brief
# routing comment on the originating surface, then SSHes onward to the
# chosen employee and runs the appropriate n8n-agent-* script. The
# employee's stdout/stderr is streamed straight back so n8n's downstream
# nodes see the same output contract they always have.
#
# Usage:
#   n8n-manager-dispatch <args-b64>
#
# Where <args-b64> is base64 of a JSON object emitted by the workflow's
# "Build args" Code node. Schema:
#
# {
#   surface: "<surface-name>",       # selects downstream script + reply path
#   repoOwner, repoName, repoFull,   # always
#   senderLogin, senderType,         # for bot-loop check
#   bodyText,                        # free text used by claude-routing
#   title,                           # optional, used by claude-routing
#   mentionedLogin?,                 # explicit @-mention if any
#   assigneeLogin?,                  # explicit assignment if any
#   reviewerLogin?,                  # explicit review-requested if any
#   promptB64,                       # the prompt the chosen employee will run
#   ...surface-specific fields:
#     issueNumber, issueTitle, issueBody, issueUrl
#     prNumber, prTitle, prBody, prHeadRef, prBaseRef, prHeadSha, prAuthor
#     branch, commentId, commentBody, commentUrl, path, line, diffHunk
#     reviewBody, reviewState, reviewUrl
#     discussionNodeId, discussionNumber, discussionTitle, discussionBody,
#       discussionUrl, discussionCategory, replyToNodeId
#     mergeMethod, prTitle (for /merge)
# }
#
# Surfaces (one per workflow):
#   issue-action          — workflow 01/07 — implementer opens a PR for an issue
#   issue-body            — workflow 08 — conversational reply on issue body mention
#   pr-body               — workflow 09 — conversational reply on PR body mention
#   pr-review             — workflow 10 — conversational reply on PR review mention
#   pr-review-requested   — workflow 04 — reviewer posts a formal review
#   pr-address            — workflow 05 — implementer pushes a fix in response to comment
#   pr-build              — workflow 03 — /build slash on PR
#   pr-merge              — workflow 06 — /merge slash on PR
#   release-merge         — workflow 02 — main-branch merge → tag bump
#   discussion            — workflow 11 — discussion body mention
#   discussion-comment    — workflow 12 — discussion comment mention
#
# Output contract (consumed by n8n's downstream nodes):
#   ROUTE_DECISION=<json>
#   ROUTE_TARGET=<employee-login>
#   ROUTE_REASON=<short text>
#   ROUTE_COMMENT_RC=<int>
#   ROUTE_COMMENT_URL=<url or empty>
#   --- BEGIN EMPLOYEE OUTPUT ---
#   <verbatim stdout from the chosen employee>
#   --- END EMPLOYEE OUTPUT ---
#
# Exit code is the employee's exit code if dispatch reached that far,
# otherwise a code in the 10-19 range for routing failures.
set +e
set -o pipefail

CONFIG="${EMPLOYEES_CONFIG:-/etc/onym/employees.json}"
SSH_KEY="${MANAGER_SSH_KEY:-$HOME/.ssh/manager-fanout}"

# n8n's SSH session doesn't inherit the container's GITHUB_TOKEN, and
# `gh auth login --with-token` at first-run is best-effort (errors
# swallowed). Load the token from ~/.gh-token (written by first-run.sh)
# so `gh issue/pr/api` calls below always have credentials.
if [ -z "${GH_TOKEN:-}" ] && [ -r "$HOME/.gh-token" ]; then
  GH_TOKEN=$(cat "$HOME/.gh-token")
  export GH_TOKEN
fi

ARGS_B64="${1:-}"
if [ -z "$ARGS_B64" ]; then
  echo "ERROR: usage: n8n-manager-dispatch <args-b64>" >&2
  exit 2
fi
if [ ! -r "$CONFIG" ]; then
  echo "ERROR: $CONFIG missing or unreadable — mount employees.json into /etc/onym/" >&2
  exit 10
fi

ARGS=$(echo "$ARGS_B64" | base64 -d) || { echo "ERROR: bad base64 for args" >&2; exit 11; }
SURFACE=$(echo "$ARGS" | jq -r '.surface // ""')
if [ -z "$SURFACE" ]; then
  echo "ERROR: args.surface missing" >&2
  exit 12
fi

# ---- 1. Bot-loop guard --------------------------------------------------
SENDER_LOGIN=$(echo "$ARGS" | jq -r '.senderLogin // ""')
SENDER_TYPE=$(echo "$ARGS" | jq -r '.senderType // ""')
ALL_BOT_LOGINS=$(jq -r '
  [.manager.githubLogin]
    + (.employees | to_entries | map(.value.githubLogin))
    + ["github-actions[bot]"]
  | unique | join(",")
' "$CONFIG")
if [ "$SENDER_TYPE" = "Bot" ]; then
  echo "DROPPED=sender-type-bot"
  exit 0
fi
if [ -n "$SENDER_LOGIN" ] && echo ",$ALL_BOT_LOGINS," | grep -q ",$SENDER_LOGIN,"; then
  echo "DROPPED=sender-is-mapped-bot login=$SENDER_LOGIN"
  exit 0
fi

# ---- 2. Pick target employee --------------------------------------------
is_employee() {
  jq -e --arg l "$1" '.employees | has($l)' "$CONFIG" >/dev/null
}
default_for() {
  jq -r --arg k "$1" '.defaults[$k] // ""' "$CONFIG"
}

MENTIONED=$(echo "$ARGS" | jq -r '.mentionedLogin // ""')
ASSIGNEE=$(echo "$ARGS" | jq -r '.assigneeLogin // ""')
REVIEWER_REQUESTED=$(echo "$ARGS" | jq -r '.reviewerLogin // ""')

TARGET=""
ROUTE_REASON=""
ROUTE_CONFIDENCE=""

# Explicit signals beat inference, in this order:
if [ -n "$MENTIONED" ] && is_employee "$MENTIONED"; then
  TARGET="$MENTIONED"
  ROUTE_REASON="explicit @-mention"
  ROUTE_CONFIDENCE="1.0"
elif [ -n "$REVIEWER_REQUESTED" ] && is_employee "$REVIEWER_REQUESTED"; then
  TARGET="$REVIEWER_REQUESTED"
  ROUTE_REASON="explicit review request"
  ROUTE_CONFIDENCE="1.0"
elif [ -n "$ASSIGNEE" ] && is_employee "$ASSIGNEE"; then
  TARGET="$ASSIGNEE"
  ROUTE_REASON="explicit assignment"
  ROUTE_CONFIDENCE="1.0"
fi

# Surface-specific defaults (don't ask claude when the surface is wholly
# mechanical — release-merge, /merge, /build).
if [ -z "$TARGET" ]; then
  case "$SURFACE" in
    release-merge|pr-build|pr-merge)
      TARGET=$(default_for implementer)
      ROUTE_REASON="default implementer (mechanical surface)"
      ROUTE_CONFIDENCE="1.0"
      ;;
    pr-review-requested)
      TARGET=$(default_for reviewer)
      ROUTE_REASON="default reviewer"
      ROUTE_CONFIDENCE="1.0"
      ;;
  esac
fi

# Otherwise let claude pick by inspecting specializations. The prompt
# template is mounted at $ROUTING_PROMPT_TMPL (default /etc/onym/...)
# so it can be tuned without rebuilding the agent image — edit, the
# next dispatch picks it up. If the file is missing or unreadable, we
# fall back to the embedded heredoc below so the system keeps working
# even when the host-side mount is broken.
if [ -z "$TARGET" ]; then
  EMP_BLOCK=$(jq -r '
    .employees | to_entries[]
    | "- @\(.key): specialization=\(.value.specialization // "n/a") | tags=\(.value.tags // [] | join(","))"
  ' "$CONFIG")
  TITLE=$(echo "$ARGS" | jq -r '.title // ""')
  BODY=$(echo "$ARGS" | jq -r '.bodyText // ""' | head -c 4000)
  REPO_FULL_TMPL=$(echo "$ARGS" | jq -r '"\(.repoOwner)/\(.repoName)"')
  DEFAULT_IMPL=$(default_for implementer)
  export EMP_BLOCK SURFACE TITLE BODY DEFAULT_IMPL SENDER_LOGIN
  export REPO_FULL="$REPO_FULL_TMPL"

  PROMPT_TMPL_PATH="${ROUTING_PROMPT_TMPL:-/etc/onym/routing-prompt.tmpl}"
  if [ -r "$PROMPT_TMPL_PATH" ]; then
    # Allowlist the variables we substitute — leaves any other ${...}
    # in the template literal (so a prompt that mentions e.g.
    # ${HOME} doesn't surprise-expand).
    ROUTING_PROMPT=$(envsubst '$EMP_BLOCK $SURFACE $TITLE $BODY $DEFAULT_IMPL $SENDER_LOGIN $REPO_FULL' < "$PROMPT_TMPL_PATH")
  else
    ROUTING_PROMPT=$(cat <<EOF
You are routing one inbound GitHub event to the best employee. Employees:
$EMP_BLOCK

Surface: $SURFACE
Repo: $REPO_FULL
Sender: @$SENDER_LOGIN
Title: $TITLE
Body (truncated):
---
$BODY
---

Pick exactly one employee whose specialization fits best. Output a single
JSON object on one line, no fences, no preamble:
{"employee":"<login>","confidence":<float 0..1>,"reason":"<one short sentence>"}

If unsure (confidence < 0.5), pick "$DEFAULT_IMPL".
EOF
    )
  fi
  CLAUDE_OUT=$(printf '%s' "$ROUTING_PROMPT" | claude --print --dangerously-skip-permissions 2>/dev/null)
  CLAUDE_RC=$?
  ROUTE_JSON=$(printf '%s\n' "$CLAUDE_OUT" | grep -Eo '\{[^{}]*"employee"[^{}]*\}' | head -1)
  if [ "$CLAUDE_RC" -eq 0 ] && [ -n "$ROUTE_JSON" ]; then
    PICK=$(echo "$ROUTE_JSON" | jq -r '.employee // ""' 2>/dev/null)
    CONF=$(echo "$ROUTE_JSON" | jq -r '.confidence // 0' 2>/dev/null)
    REASON=$(echo "$ROUTE_JSON" | jq -r '.reason // ""' 2>/dev/null)
    if [ -n "$PICK" ] && is_employee "$PICK"; then
      TARGET="$PICK"
      ROUTE_REASON="claude: $REASON"
      ROUTE_CONFIDENCE="$CONF"
    fi
  fi
fi

# Last-ditch fallback.
if [ -z "$TARGET" ]; then
  TARGET=$(default_for implementer)
  ROUTE_REASON="fallback to default implementer"
  ROUTE_CONFIDENCE="0.0"
  if [ -z "$TARGET" ]; then
    echo "ERROR: no defaults.implementer in $CONFIG and no route found" >&2
    exit 13
  fi
fi

ROUTE_DECISION=$(jq -nc --arg t "$TARGET" --arg r "$ROUTE_REASON" --arg c "$ROUTE_CONFIDENCE" \
  '{employee:$t, reason:$r, confidence:($c|tonumber? // 0)}')
echo "ROUTE_DECISION=$ROUTE_DECISION"
echo "ROUTE_TARGET=$TARGET"
echo "ROUTE_REASON=$ROUTE_REASON"

# ---- 3. Post visible routing comment as the manager bot -----------------
# This uses the manager container's own gh auth (its GITHUB_TOKEN is the
# manager bot's PAT). Surface-aware reply mechanism, mirroring the
# n8n-agent-reply.sh shape.
post_routing_comment() {
  local target="$1" reason="$2" surface="$3"
  local body_file="/tmp/route-comment-$$.md"
  cat > "$body_file" <<MSG
**Routed to @$target.**

_$reason_

@$target will respond shortly. Cross-mention me (\`@$(jq -r '.manager.githubLogin' "$CONFIG")\`) on this thread to override and re-route.
MSG
  local owner repo issue pr disc reply_to
  owner=$(echo "$ARGS" | jq -r '.repoOwner // ""')
  repo=$(echo "$ARGS" | jq -r '.repoName // ""')
  case "$surface" in
    issue-action|issue-body)
      issue=$(echo "$ARGS" | jq -r '.issueNumber // 0')
      if [ -n "$owner" ] && [ "$issue" -gt 0 ]; then
        local out rc url
        out=$(gh issue comment "$issue" --repo "$owner/$repo" --body-file "$body_file" 2>&1)
        rc=$?
        url=$(printf '%s\n' "$out" | grep -Eo 'https://github.com/[^ ]+#issuecomment-[0-9]+' | tail -1)
        echo "ROUTE_COMMENT_RC=$rc"
        echo "ROUTE_COMMENT_URL=$url"
        [ "$rc" -ne 0 ] && printf '%s\n' "$out" | sed 's/^/  routing-comment: /' >&2
      else
        echo "ROUTE_COMMENT_RC=0"
        echo "ROUTE_COMMENT_URL="
      fi
      ;;
    pr-body|pr-review|pr-address|pr-build|pr-merge|pr-review-requested)
      pr=$(echo "$ARGS" | jq -r '.prNumber // 0')
      if [ -n "$owner" ] && [ "$pr" -gt 0 ]; then
        local out rc url
        out=$(gh pr comment "$pr" --repo "$owner/$repo" --body-file "$body_file" 2>&1)
        rc=$?
        url=$(printf '%s\n' "$out" | grep -Eo 'https://github.com/[^ ]+#issuecomment-[0-9]+' | tail -1)
        echo "ROUTE_COMMENT_RC=$rc"
        echo "ROUTE_COMMENT_URL=$url"
        [ "$rc" -ne 0 ] && printf '%s\n' "$out" | sed 's/^/  routing-comment: /' >&2
      else
        echo "ROUTE_COMMENT_RC=0"
        echo "ROUTE_COMMENT_URL="
      fi
      ;;
    discussion|discussion-comment)
      disc=$(echo "$ARGS" | jq -r '.discussionNodeId // ""')
      reply_to=$(echo "$ARGS" | jq -r '.replyToNodeId // ""')
      if [ -n "$disc" ]; then
        local body_json query out rc url
        body_json=$(jq -Rs . < "$body_file")
        if [ -n "$reply_to" ]; then
          query=$(jq -nc --arg disc "$disc" --arg reply "$reply_to" --argjson body "$body_json" '{
            query: "mutation($d:ID!,$r:ID!,$b:String!){addDiscussionComment(input:{discussionId:$d,replyToId:$r,body:$b}){comment{url}}}",
            variables: {d:$disc,r:$reply,b:$body}
          }')
        else
          query=$(jq -nc --arg disc "$disc" --argjson body "$body_json" '{
            query: "mutation($d:ID!,$b:String!){addDiscussionComment(input:{discussionId:$d,body:$b}){comment{url}}}",
            variables: {d:$disc,b:$body}
          }')
        fi
        out=$(printf '%s' "$query" | gh api graphql --input - 2>&1)
        rc=$?
        url=$(printf '%s\n' "$out" | jq -r '.data.addDiscussionComment.comment.url // empty' 2>/dev/null || true)
        echo "ROUTE_COMMENT_RC=$rc"
        echo "ROUTE_COMMENT_URL=$url"
        [ "$rc" -ne 0 ] && printf '%s\n' "$out" | sed 's/^/  routing-comment: /' >&2
      else
        echo "ROUTE_COMMENT_RC=0"
        echo "ROUTE_COMMENT_URL="
      fi
      ;;
    release-merge|*)
      # No conversational anchor for release-merge — the audit trail is
      # the tag push itself. Skip the comment.
      echo "ROUTE_COMMENT_RC=0"
      echo "ROUTE_COMMENT_URL="
      ;;
  esac
  rm -f "$body_file"
}

post_routing_comment "$TARGET" "$ROUTE_REASON" "$SURFACE"

# ---- 4. SSH to chosen employee and run downstream script ----------------
ENTRY=$(jq -c --arg t "$TARGET" '.employees[$t]' "$CONFIG")
EHOST=$(echo "$ENTRY" | jq -r '.host')
EPORT=$(echo "$ENTRY" | jq -r '.port // 22')
EUSER=$(echo "$ENTRY" | jq -r '.user // "agent"')

REPO_FULL=$(echo "$ARGS" | jq -r '"\(.repoOwner)/\(.repoName)"')
REPO_SLUG="${REPO_FULL//\//__}"
PROMPT_B64=$(echo "$ARGS" | jq -r '.promptB64 // ""')

# Per-branch flock so two webhooks targeting the same employee + same
# branch queue rather than race on the worktree. Lock keys are namespaced
# by repo slug so unrelated repos on the same employee stay independent.
# Conversational reply surfaces have no branch and serialize on a single
# per-repo "workspace" key (they all share the primary workspace cwd
# that gets `git reset --hard`'d after each run). See bin/n8n-agent-lock.
build_remote_cmd() {
  local surface="$1"
  local issue pr branch target lock_key
  case "$surface" in
    issue-action)
      issue=$(echo "$ARGS" | jq -r '.issueNumber')
      lock_key="${REPO_SLUG}__agent/issue-${issue}"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\ngit fetch origin main >/dev/null 2>&1\ngit checkout -f -B main origin/main >/dev/null 2>&1\nexec n8n-agent-lock %q n8n-agent-issue %q %q %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$issue" \
        "$PROMPT_B64" \
        "$(echo "$ARGS" | jq -r '.reviewerLogin // ""')"
      ;;
    pr-address)
      pr=$(echo "$ARGS" | jq -r '.prNumber')
      branch=$(echo "$ARGS" | jq -r '.branch')
      lock_key="${REPO_SLUG}__${branch}"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\nexec n8n-agent-lock %q n8n-agent-address %q %q %q %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$pr" \
        "$branch" \
        "$(echo "$ARGS" | jq -r '.commentId')" \
        "$PROMPT_B64"
      ;;
    pr-review-requested)
      pr=$(echo "$ARGS" | jq -r '.prNumber')
      lock_key="${REPO_SLUG}__pr-${pr}-review"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\nexec n8n-agent-lock %q n8n-agent-review %q %q %q %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$pr" \
        "$(echo "$ARGS" | jq -r '.prBaseRef')" \
        "$(echo "$ARGS" | jq -r '.prHeadSha')" \
        "$PROMPT_B64"
      ;;
    issue-body)
      lock_key="${REPO_SLUG}__workspace"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\nexec n8n-agent-lock %q n8n-agent-reply issue %q %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$PROMPT_B64" \
        "$(echo "$ARGS" | jq -r '.issueNumber')"
      ;;
    pr-body|pr-review)
      lock_key="${REPO_SLUG}__workspace"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\nexec n8n-agent-lock %q n8n-agent-reply pr %q %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$PROMPT_B64" \
        "$(echo "$ARGS" | jq -r '.prNumber')"
      ;;
    discussion)
      lock_key="${REPO_SLUG}__workspace"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\nexec n8n-agent-lock %q n8n-agent-reply discussion %q %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$PROMPT_B64" \
        "$(echo "$ARGS" | jq -r '.discussionNodeId')"
      ;;
    discussion-comment)
      lock_key="${REPO_SLUG}__workspace"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\nexec n8n-agent-lock %q n8n-agent-reply discussion-reply %q %q %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$PROMPT_B64" \
        "$(echo "$ARGS" | jq -r '.discussionNodeId')" \
        "$(echo "$ARGS" | jq -r '.replyToNodeId // ""')"
      ;;
    pr-build)
      # Specialised — runs the build script directly. The prompt isn't a
      # claude prompt for /build; it carries the {sha,target} the build
      # wrapper needs.
      pr=$(echo "$ARGS" | jq -r '.prNumber')
      target=$(echo "$ARGS" | jq -r '.buildTarget')
      lock_key="${REPO_SLUG}__pr-${pr}-build-${target}"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\nexec n8n-agent-lock %q n8n-agent-build %q %q %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$pr" \
        "$target" \
        "$(echo "$ARGS" | jq -r '.headSha')"
      ;;
    pr-merge)
      pr=$(echo "$ARGS" | jq -r '.prNumber')
      lock_key="${REPO_SLUG}__pr-${pr}"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\nexec n8n-agent-lock %q n8n-agent-merge %q %q %q %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$pr" \
        "$(echo "$ARGS" | jq -r '.mergeMethod // "squash"')" \
        "$(echo "$ARGS" | jq -r '.prTitle')" \
        "$(default_for humanQa)"
      ;;
    release-merge)
      lock_key="${REPO_SLUG}__main-release"
      printf 'set +e\neval "$(n8n-agent-prep %q)" || exit $?\nexec n8n-agent-lock %q n8n-agent-release-bump %q\n' \
        "$REPO_FULL" \
        "$lock_key" \
        "$(echo "$ARGS" | jq -r '.bump // "patch"')"
      ;;
    *)
      printf 'echo "ERROR: unknown surface %s" >&2; exit 99\n' "$surface"
      ;;
  esac
}

REMOTE_CMD=$(build_remote_cmd "$SURFACE")

# Fire an :eyes: reaction on the triggering surface as the chosen
# employee bot, before the (potentially slow) main work begins. The
# script lives on the employee container and uses that container's
# GITHUB_TOKEN, so the reaction shows up as e.g. @dev-onym, not as the
# manager. Best-effort — failures here never block the main dispatch.
SSH_OPTS=(-i "$SSH_KEY" -p "$EPORT"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$HOME/.ssh/manager-known-hosts")
case "$SURFACE" in
  release-merge|pr-build|pr-merge)
    # Mechanical surfaces — no human comment to react to. Skip.
    ;;
  *)
    REACT_CMD=$(printf 'n8n-agent-react eyes %q\n' "$ARGS_B64")
    ssh "${SSH_OPTS[@]}" "$EUSER@$EHOST" "$REACT_CMD" >/dev/null 2>&1 &
    ;;
esac

echo "--- BEGIN EMPLOYEE OUTPUT ---"
ssh "${SSH_OPTS[@]}" "$EUSER@$EHOST" "$REMOTE_CMD"
EMP_RC=$?
echo "--- END EMPLOYEE OUTPUT ---"
echo "EMPLOYEE_RC=$EMP_RC"

# Wait for the (typically already-finished) reaction SSH so we don't
# leave a zombie if the parent process exits immediately.
wait 2>/dev/null

exit "$EMP_RC"
