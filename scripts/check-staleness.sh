#!/bin/bash
# check-staleness.sh — exit 0 if the feature branch is within merge-safe distance of autodev,
# exit 2 if stale enough that the Releaser should abort instead of rebasing.
#
# Usage: check-staleness.sh --pr <N> [--max 30] [--repo amonick12/helix]

set -euo pipefail

PR=""; MAX=30; REPO="amonick12/helix"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)   PR="$2"; shift 2 ;;
    --max)  MAX="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$PR" ]] && { echo "Usage: $0 --pr <N> [--max 30]" >&2; exit 1; }

HEAD_REF=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq '.headRefName')
BASE_REF=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName')

git fetch origin "$HEAD_REF" "$BASE_REF" --quiet 2>/dev/null || true

COUNT=$(git rev-list --count "origin/$BASE_REF..origin/$HEAD_REF" 2>/dev/null || echo 9999)

jq -n --arg pr "$PR" --arg head "$HEAD_REF" --arg base "$BASE_REF" \
      --argjson count "$COUNT" --argjson max "$MAX" \
      '{pr:$pr, head:$head, base:$base, commits_ahead:$count, max:$max, stale:($count > $max)}'

[[ "$COUNT" -gt "$MAX" ]] && exit 2
exit 0
