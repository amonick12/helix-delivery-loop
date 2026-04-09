#!/bin/bash
# reconcile-board.sh — Find and fix cards with missing or inconsistent fields.
#
# Usage:
#   ./reconcile-board.sh              # Auto-fix missing fields
#   ./reconcile-board.sh --dry-run    # Show what would be fixed without changing anything
#
# Fixes:
#   - Cards with no Status → set to Backlog
#   - Cards with no OwnerAgent → set based on Status column
#   - Cards in In Progress with no Branch → log warning
#
# Requires: gh CLI with project scopes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
reconcile-board.sh — Find and fix cards with missing or inconsistent fields.

Usage:
  ./reconcile-board.sh              # Auto-fix missing fields
  ./reconcile-board.sh --dry-run    # Show what would be fixed

Fixes applied:
  - Cards with no Status field       → Status set to Backlog
  - Cards with no OwnerAgent field   → OwnerAgent set based on Status:
      Backlog/Ready → Scout, In Progress → Builder, In Review → Reviewer, Done → Releaser
  - Cards in "In Progress" with no Branch → warning logged (no auto-fix)

Requires: gh CLI with project scopes
HELP

DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *)         echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

echo "=== Board Reconciliation ==="
echo ""

# Read full board state (force fresh)
BOARD=$("$SCRIPT_DIR/read-board.sh" --no-cache)
FIXES=0
WARNINGS=0

# Default OwnerAgent by Status
owner_for_status() {
  case "$1" in
    "Backlog"|"Ready") echo "Scout" ;;
    "In progress"|"In Progress") echo "Builder" ;;
    "In review"|"In Review") echo "Reviewer" ;;
    "Done") echo "Releaser" ;;
    *) echo "Scout" ;;
  esac
}

# Process each card
CARD_COUNT=$(echo "$BOARD" | jq '.cards | length')

for i in $(seq 0 $(( CARD_COUNT - 1 ))); do
  CARD=$(echo "$BOARD" | jq ".cards[$i]")
  ISSUE_NUM=$(echo "$CARD" | jq -r '.issue_number // empty')
  TITLE=$(echo "$CARD" | jq -r '.title')
  STATUS=$(echo "$CARD" | jq -r '.fields.Status // empty')
  OWNER_AGENT=$(echo "$CARD" | jq -r '.fields.OwnerAgent // empty')
  BRANCH=$(echo "$CARD" | jq -r '.fields.Branch // empty')

  if [[ -z "$ISSUE_NUM" ]]; then
    continue  # Skip draft items without issue numbers
  fi

  # Fix: Missing Status
  if [[ -z "$STATUS" ]]; then
    echo "FIX: #$ISSUE_NUM ($TITLE) — missing Status → Backlog"
    if [[ "$DRY_RUN" == "false" ]]; then
      "$SCRIPT_DIR/move-card.sh" --issue "$ISSUE_NUM" --to "Backlog" 2>/dev/null || \
        echo "  ! Failed to set Status=Backlog" >&2
    fi
    STATUS="Backlog"
    FIXES=$((FIXES + 1))
  fi

  # Fix: Missing OwnerAgent
  if [[ -z "$OWNER_AGENT" ]]; then
    DEFAULT_OWNER=$(owner_for_status "$STATUS")
    echo "FIX: #$ISSUE_NUM ($TITLE) — missing OwnerAgent → $DEFAULT_OWNER (based on Status=$STATUS)"
    if [[ "$DRY_RUN" == "false" ]]; then
      "$SCRIPT_DIR/set-field.sh" --issue "$ISSUE_NUM" --field "OwnerAgent" --value "$DEFAULT_OWNER" 2>/dev/null || \
        echo "  ! Failed to set OwnerAgent=$DEFAULT_OWNER" >&2
    fi
    FIXES=$((FIXES + 1))
  fi

  # Warn: In Progress without Branch
  if [[ ("$STATUS" == "In progress" || "$STATUS" == "In Progress") && -z "$BRANCH" ]]; then
    echo "WARN: #$ISSUE_NUM ($TITLE) — In Progress but no Branch set"
    WARNINGS=$((WARNINGS + 1))
  fi
done

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== Dry run complete — $FIXES fixes would be applied, $WARNINGS warnings ==="
else
  echo "=== Reconciliation complete — $FIXES fixes applied, $WARNINGS warnings ==="
fi
