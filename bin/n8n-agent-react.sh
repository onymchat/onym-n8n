#!/usr/bin/env bash
# Fire a GitHub reaction emoji on the surface that triggered an employee.
# Invoked by n8n-manager-dispatch.sh just before the main employee work,
# so the human who summoned the bot sees an immediate :eyes: ack while
# claude churns.
#
# Runs on the EMPLOYEE container (uses that employee's GITHUB_TOKEN), so
# the reaction is attributed to e.g. @dev-onym, not the manager bot.
#
# Usage:
#   n8n-agent-react <reaction> <args-json-b64>
#
# Where <args-json-b64> is the same args blob the dispatcher gets. We
# look at .surface to decide which API to hit, and read whichever of
# .commentId / .issueNumber / .prNumber / .discussionNodeId apply.
#
# Best-effort: never fails — a missing reaction is cosmetic, not load-
# bearing for the work that follows.
set +e

REACTION="${1:-eyes}"
ARGS_B64="${2:-}"

if [ -z "$ARGS_B64" ]; then
  exit 0
fi

# n8n's SSH session doesn't inherit the container's GITHUB_TOKEN.
# first-run.sh writes it to ~/.gh-token; load it here so `gh api` calls
# below have credentials.
if [ -z "${GH_TOKEN:-}" ] && [ -r "$HOME/.gh-token" ]; then
  GH_TOKEN=$(cat "$HOME/.gh-token")
  export GH_TOKEN
fi

ARGS=$(echo "$ARGS_B64" | base64 -d 2>/dev/null) || exit 0

surface=$(echo "$ARGS" | jq -r '.surface // ""')
owner=$(echo "$ARGS"  | jq -r '.repoOwner // ""')
repo=$(echo "$ARGS"   | jq -r '.repoName // ""')
[ -z "$surface" ] || [ -z "$owner" ] || [ -z "$repo" ] && exit 0

# REST reactions take a lowercase short name; GraphQL takes an enum.
case "$REACTION" in
  eyes)    REST_EMOJI=eyes;    GQL_EMOJI=EYES ;;
  +1)      REST_EMOJI=+1;      GQL_EMOJI=THUMBS_UP ;;
  -1)      REST_EMOJI=-1;      GQL_EMOJI=THUMBS_DOWN ;;
  rocket)  REST_EMOJI=rocket;  GQL_EMOJI=ROCKET ;;
  hooray)  REST_EMOJI=hooray;  GQL_EMOJI=HOORAY ;;
  heart)   REST_EMOJI=heart;   GQL_EMOJI=HEART ;;
  laugh)   REST_EMOJI=laugh;   GQL_EMOJI=LAUGH ;;
  *)       REST_EMOJI="$REACTION"; GQL_EMOJI=EYES ;;
esac

react_issue_comment() {
  local cid="$1"
  [ -n "$cid" ] && [ "$cid" != "null" ] || return 0
  gh api -X POST "repos/$owner/$repo/issues/comments/$cid/reactions" \
    -f content="$REST_EMOJI" >/dev/null 2>&1
}
react_pr_review_comment() {
  local cid="$1"
  [ -n "$cid" ] && [ "$cid" != "null" ] || return 0
  gh api -X POST "repos/$owner/$repo/pulls/comments/$cid/reactions" \
    -f content="$REST_EMOJI" >/dev/null 2>&1
}
react_issue_or_pr() {
  local num="$1"
  [ -n "$num" ] && [ "$num" != "null" ] && [ "$num" != "0" ] || return 0
  gh api -X POST "repos/$owner/$repo/issues/$num/reactions" \
    -f content="$REST_EMOJI" >/dev/null 2>&1
}
react_node() {
  local node_id="$1"
  [ -n "$node_id" ] && [ "$node_id" != "null" ] || return 0
  local query
  query=$(jq -nc --arg id "$node_id" --arg c "$GQL_EMOJI" '{
    query: "mutation($i:ID!,$c:ReactionContent!){addReaction(input:{subjectId:$i,content:$c}){clientMutationId}}",
    variables: { i: $id, c: $c }
  }')
  printf '%s' "$query" | gh api graphql --input - >/dev/null 2>&1
}

cid=$(echo "$ARGS"          | jq -r '.commentId // ""')
issue_num=$(echo "$ARGS"    | jq -r '.issueNumber // ""')
pr_num=$(echo "$ARGS"       | jq -r '.prNumber // ""')
disc_node=$(echo "$ARGS"    | jq -r '.discussionNodeId // ""')
comment_node=$(echo "$ARGS" | jq -r '.commentNodeId // ""')

case "$surface" in
  issue-action)
    # Comment-triggered (workflow 07) carries .commentId; assignment-
    # triggered (workflow 01) doesn't — fall back to the issue itself.
    if [ -n "$cid" ] && [ "$cid" != "null" ]; then
      react_issue_comment "$cid"
    else
      react_issue_or_pr "$issue_num"
    fi
    ;;
  issue-body)
    react_issue_or_pr "$issue_num"
    ;;
  pr-body|pr-review)
    react_issue_or_pr "$pr_num"
    ;;
  pr-address)
    react_pr_review_comment "$cid"
    ;;
  discussion)
    react_node "$disc_node"
    ;;
  discussion-comment)
    if [ -n "$comment_node" ] && [ "$comment_node" != "null" ]; then
      react_node "$comment_node"
    else
      react_node "$disc_node"
    fi
    ;;
esac

exit 0
