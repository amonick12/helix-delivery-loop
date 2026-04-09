#!/bin/bash
# detect-ui-changes.sh — Determine if a card has UI changes by analyzing acceptance criteria.
#
# Usage:
#   ./detect-ui-changes.sh --card 137
#
# Output: JSON { "has_ui_changes": true/false, "reason": "..." }
#
# Env:
#   DRY_RUN=1   Skip gh calls, use mock data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
detect-ui-changes.sh — Determine if a card has UI changes by analyzing acceptance criteria.

Usage:
  ./detect-ui-changes.sh --card 137

Options:
  --card <N>    Issue number (required)

Output: JSON { "has_ui_changes": true/false, "reason": "..." }

Also sets HasUIChanges field on the card via set-field.sh.

Env:
  DRY_RUN=1   Skip gh calls, use mock data
HELP

# ── Parse args ─────────────────────────────────────────
CARD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card) CARD="$2"; shift 2 ;;
    *)      log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$CARD" ]]; then
  log_error "--card <number> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Visual keywords pattern (same as generate-design.sh) ──
VISUAL_PATTERN='(view|layout|screen|tab|UI|display|show|render|design|button|icon|animation|color|theme|card|list|grid|modal|sheet|nav|header|footer|image|text style|font|spacing|padding|margin|empty state|populated|scroll|tap|swipe)'

# ── Fetch issue body ──────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  ISSUE_BODY="${MOCK_ISSUE_BODY:-## Acceptance Criteria\n- [ ] Add new view for journal export\n- [ ] Show confirmation dialog}"
  ISSUE_TITLE="${MOCK_ISSUE_TITLE:-Test Card}"
else
  ISSUE_BODY=$(gh issue view "$CARD" --repo "$REPO" --json body -q '.body' 2>/dev/null || echo "")
  ISSUE_TITLE=$(gh issue view "$CARD" --repo "$REPO" --json title -q '.title' 2>/dev/null || echo "")
fi

if [[ -z "$ISSUE_BODY" && -z "$ISSUE_TITLE" ]]; then
  log_error "Could not fetch issue #$CARD"
  exit 1
fi

# ── Extract acceptance criteria ───────────────────────
CRITERIA=$(echo -e "$ISSUE_BODY" | grep -E '^\s*-\s*\[[ xX]\]' | sed 's/^\s*-\s*\[[ xX]\]\s*//' || true)

# Combine title + criteria for analysis
SEARCHABLE_TEXT="$ISSUE_TITLE $CRITERIA"

# ── Check for visual keywords ─────────────────────────
MATCHED_KEYWORDS=""
if echo "$SEARCHABLE_TEXT" | grep -iqE "$VISUAL_PATTERN"; then
  HAS_UI=true
  # Extract which keywords matched
  MATCHED_KEYWORDS=$(echo "$SEARCHABLE_TEXT" | grep -ioE "$VISUAL_PATTERN" | sort -u | tr '\n' ', ' | sed 's/,$//')
  REASON="Visual keywords found in acceptance criteria: $MATCHED_KEYWORDS"
else
  HAS_UI=false
  REASON="No visual keywords found in title or acceptance criteria"
fi

# ── Set field on card ─────────────────────────────────
if [[ "$HAS_UI" == "true" ]]; then
  FIELD_VALUE="Yes"
else
  FIELD_VALUE="No"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log_info "[DRY_RUN] Would set HasUIChanges=$FIELD_VALUE on card #$CARD"
else
  "$SCRIPT_DIR/set-field.sh" --issue "$CARD" --field "HasUIChanges" --value "$FIELD_VALUE" 2>/dev/null || \
    log_warn "Could not set HasUIChanges on card #$CARD"
fi

# ── Output JSON ───────────────────────────────────────
jq -n \
  --argjson has_ui_changes "$HAS_UI" \
  --arg reason "$REASON" \
  '{has_ui_changes: $has_ui_changes, reason: $reason}'
