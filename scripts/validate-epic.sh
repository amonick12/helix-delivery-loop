#!/bin/bash
# validate-epic.sh — Enforce the epic approval flow.
# Prevents sub-card creation until the epic is approved by the user.
#
# Usage:
#   ./validate-epic.sh --epic <N>              # Check if epic is approved
#   ./validate-epic.sh --epic <N> --approve    # Mark epic as approved (user only)
#   ./validate-epic.sh --card <N>              # Check if card's parent epic is approved
#
# Exit 0: epic is approved, safe to create sub-cards
# Exit 1: epic NOT approved, block sub-card creation
#
# Epic approval flow:
#   1. Scout creates epic card with PRD (label: epic, prd)
#   2. Designer creates mockups for all screens
#   3. User approves by adding `epic-approved` label
#   4. Only then can Planner/dispatcher create sub-cards
#
# This script is called by create-card.sh to gate sub-card creation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

EPIC=""
CARD=""
APPROVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --epic)    EPIC="$2"; shift 2 ;;
    --card)    CARD="$2"; shift 2 ;;
    --approve) APPROVE=true; shift ;;
    -h|--help) echo "Usage: validate-epic.sh --epic <N> | --card <N> | --epic <N> --approve"; exit 0 ;;
    *)         echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

# If checking a card, find its parent epic from the issue body
if [[ -n "$CARD" && -z "$EPIC" ]]; then
  BODY=$(gh issue view "$CARD" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
  # Look for "Part of epic #N" or "Epic: #N" patterns
  EPIC=$(echo "$BODY" | grep -oE '(Epic|epic|Part of.*epic)[:#]?\s*#?([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)
  if [[ -z "$EPIC" ]]; then
    # No parent epic — card is standalone, allow creation
    echo "OK: Card #$CARD has no parent epic — standalone card allowed"
    exit 0
  fi
fi

if [[ -z "$EPIC" ]]; then
  echo "Error: --epic <N> or --card <N> required" >&2
  exit 1
fi

# Check if epic has the `epic-approved` label
LABELS=$(gh issue view "$EPIC" --repo "$REPO" --json labels --jq '[.labels[].name]' 2>/dev/null || echo "[]")
HAS_APPROVED=$(echo "$LABELS" | jq 'any(. == "epic-approved")' 2>/dev/null || echo "false")
HAS_EPIC=$(echo "$LABELS" | jq 'any(. == "epic")' 2>/dev/null || echo "false")

if [[ "$APPROVE" == "true" ]]; then
  # Add epic-approved label
  gh issue edit "$EPIC" --repo "$REPO" --add-label "epic-approved" 2>/dev/null
  echo "Epic #$EPIC marked as approved"
  exit 0
fi

if [[ "$HAS_EPIC" != "true" ]]; then
  echo "OK: Issue #$EPIC is not an epic — no approval needed"
  exit 0
fi

if [[ "$HAS_APPROVED" == "true" ]]; then
  echo "OK: Epic #$EPIC is approved — sub-cards allowed"
  exit 0
else
  echo "BLOCKED: Epic #$EPIC has NOT been approved by the user. Do not create sub-cards." >&2
  echo "The user must add the 'epic-approved' label before sub-cards can be created." >&2
  exit 1
fi
