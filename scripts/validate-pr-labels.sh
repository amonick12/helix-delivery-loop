#!/bin/bash
# validate-pr-labels.sh — Check and fix contradictory PR labels.
# Run after any label change to ensure consistency.
#
# Usage:
#   ./validate-pr-labels.sh --pr N
#
# Fixes:
#   - awaiting-visual-qa + visual-qa-approved → remove awaiting-visual-qa
#   - tests-passed without code-review-approved → remove tests-passed
#   - rework + code-review-approved → remove code-review-approved
#   - rework + visual-qa-approved → remove visual-qa-approved

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    *)    echo "Usage: validate-pr-labels.sh --pr N" >&2; exit 1 ;;
  esac
done

[[ -z "$PR" ]] && echo "Error: --pr required" >&2 && exit 1

LABELS=$(gh pr view "$PR" --repo "$REPO" --json labels --jq '[.labels[].name]' 2>/dev/null || echo "[]")
FIXES=0

has_label() { echo "$LABELS" | jq -e "any(. == \"$1\")" > /dev/null 2>&1; }

# Fix 1: awaiting + approved
if has_label "awaiting-visual-qa" && has_label "visual-qa-approved"; then
  gh pr edit "$PR" --repo "$REPO" --remove-label "awaiting-visual-qa" 2>/dev/null
  echo "Fixed: removed awaiting-visual-qa (visual-qa-approved present)"
  FIXES=$((FIXES + 1))
fi

# Fix 2: tests-passed without code-review-approved
if has_label "tests-passed" && ! has_label "code-review-approved"; then
  gh pr edit "$PR" --repo "$REPO" --remove-label "tests-passed" 2>/dev/null
  echo "Fixed: removed tests-passed (no code-review-approved)"
  FIXES=$((FIXES + 1))
fi

# Fix 3: rework + code-review-approved
if has_label "rework" && has_label "code-review-approved"; then
  gh pr edit "$PR" --repo "$REPO" --remove-label "code-review-approved" 2>/dev/null
  echo "Fixed: removed code-review-approved (rework in progress)"
  FIXES=$((FIXES + 1))
fi

# Fix 4: rework + visual-qa-approved
if has_label "rework" && has_label "visual-qa-approved"; then
  gh pr edit "$PR" --repo "$REPO" --remove-label "visual-qa-approved" 2>/dev/null
  echo "Fixed: removed visual-qa-approved (rework in progress)"
  FIXES=$((FIXES + 1))
fi

# Fix 5: rework + tests-passed
if has_label "rework" && has_label "tests-passed"; then
  gh pr edit "$PR" --repo "$REPO" --remove-label "tests-passed" 2>/dev/null
  echo "Fixed: removed tests-passed (rework in progress)"
  FIXES=$((FIXES + 1))
fi

if [[ "$FIXES" -eq 0 ]]; then
  echo "OK: no contradictory labels on PR #$PR"
fi
