#!/bin/bash
# check-pr-comments.sh — Find unaddressed user comments on open PRs.
#
# Usage:
#   ./check-pr-comments.sh
#
# Checks all open PRs for user comments that haven't been responded to.
# Returns JSON array of PRs needing response.
#
# Output: [{"pr": N, "card": N, "comment": "...", "author": "...", "created": "..."}]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

STATE_FILE="${STATE_FILE:-$REPO_ROOT/.claude/delivery-loop-state.json}"

# Get all open PRs
OPEN_PRS=$(gh pr list --repo "$REPO" --state open --json number,headRefName,body --jq '.[].number' 2>/dev/null || echo "")

RESULTS="[]"

for PR_NUM in $OPEN_PRS; do
  # Get card number from PR body (Closes #N)
  CARD_NUM=$(gh pr view "$PR_NUM" --repo "$REPO" --json body --jq '.body' 2>/dev/null | grep -oE 'Closes #([0-9]+)' | grep -oE '[0-9]+' | head -1 || echo "")
  [[ -z "$CARD_NUM" ]] && continue

  # Get last comment check timestamp from state
  LAST_CHECK=$(jq -r --arg c "$CARD_NUM" '.cards[$c].last_comment_check // "1970-01-01T00:00:00Z"' "$STATE_FILE" 2>/dev/null || echo "1970-01-01T00:00:00Z")

  # Get user comments newer than last check (exclude bot and our own agent comments)
  NEW_COMMENTS=$(gh pr view "$PR_NUM" --repo "$REPO" --json comments --jq "[.comments[] | select(.createdAt > \"$LAST_CHECK\") | select(.author.login != \"github-actions[bot]\") | select(.body | test(\"$AGENT_COMMENT_FILTER\") | not)] | length" 2>/dev/null || echo "0")

  if [[ "$NEW_COMMENTS" -gt 0 ]]; then
    # Get the latest unaddressed comment
    LATEST=$(gh pr view "$PR_NUM" --repo "$REPO" --json comments --jq "[.comments[] | select(.createdAt > \"$LAST_CHECK\") | select(.author.login != \"github-actions[bot]\") | select(.body | test(\"$AGENT_COMMENT_FILTER\") | not)][-1] | {body: .body[:200], author: .author.login, created: .createdAt}" 2>/dev/null || echo '{}')

    RESULTS=$(echo "$RESULTS" | jq --argjson pr "$PR_NUM" --arg card "$CARD_NUM" --argjson comment "$LATEST" '. + [{"pr": $pr, "card": ($card | tonumber), "comment": $comment.body, "author": $comment.author, "created": $comment.created}]')
  fi
done

echo "$RESULTS" | jq .
