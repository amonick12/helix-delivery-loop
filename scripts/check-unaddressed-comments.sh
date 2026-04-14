#!/bin/bash
# check-unaddressed-comments.sh — Block agent finish if there are user
# comments on the PR after the most recent bot reply that have not been
# addressed.
#
# Usage:
#   ./check-unaddressed-comments.sh --pr <N>
#
# Exit 0: no unaddressed user comments (or no PR for this card)
# Exit 1: at least one user comment exists after the last bot comment.
#         Prints each unaddressed comment to stderr.
#
# This is the "did you read the comments?" gate. It catches the failure
# mode where an agent "fixes" a PR but ignored a user comment posted
# during/after the previous run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    *)    echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$PR" ]]; then
  echo "Usage: check-unaddressed-comments.sh --pr <N>" >&2
  exit 2
fi

# Fetch all comments on the PR, oldest first, with author + timestamp + body
COMMENTS_JSON=$(gh pr view "$PR" --repo "$REPO" --json comments 2>/dev/null || echo '{"comments":[]}')

# Find the timestamp of the most recent bot comment (body starts with "bot:")
LAST_BOT_TS=$(echo "$COMMENTS_JSON" | jq -r '
  .comments
  | map(select(.body | startswith("bot:") or test("bot:"; "i") | not | not))
  | sort_by(.createdAt)
  | last
  | .createdAt // ""
')

# Anything posted strictly after that timestamp by a non-bot author is
# considered unaddressed. If there is no bot comment yet, every user
# comment counts.
UNADDRESSED=$(echo "$COMMENTS_JSON" | jq -r --arg lastBot "$LAST_BOT_TS" '
  .comments
  | map(select(
      (.body | startswith("bot:") | not)
      and (if $lastBot == "" then true else .createdAt > $lastBot end)
    ))
  | length
')

if [[ "${UNADDRESSED:-0}" -gt 0 ]]; then
  echo "BLOCKED: PR #$PR has $UNADDRESSED unaddressed user comment(s) after the last bot reply." >&2
  echo "" >&2
  echo "$COMMENTS_JSON" | jq -r --arg lastBot "$LAST_BOT_TS" '
    .comments
    | map(select(
        (.body | startswith("bot:") | not)
        and (if $lastBot == "" then true else .createdAt > $lastBot end)
      ))
    | .[]
    | "  [\(.createdAt)] @\(.author.login):\n    \(.body | gsub("\n"; " ") | .[0:200])"
  ' >&2
  echo "" >&2
  echo "Address each comment before signaling finish, or post a bot: reply" >&2
  echo "explaining why the comment is being deferred." >&2
  exit 1
fi

exit 0
