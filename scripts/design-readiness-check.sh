#!/bin/bash
# design-readiness-check.sh — Validate card fields before moving to Ready.
#
# Checks that a card has all required fields and content before
# Designer moves it from Backlog to Ready.
#
# Usage:
#   ./design-readiness-check.sh --card N
#
# Output: JSON { card, ready, checks[], failures[] }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
design-readiness-check.sh — Validate card readiness before moving to Ready.

Usage:
  ./design-readiness-check.sh --card N

Checks: acceptance criteria, edge cases, scope, HasUIChanges, DesignURL, mockup.
HELP

CARD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --card) CARD="$2"; shift 2 ;;
    *)      log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$CARD" ]] && log_error "--card required" && exit 1

# Fetch issue data
ISSUE_JSON=$(gh issue view "$CARD" --repo "$REPO" --json body,labels,title,comments 2>/dev/null)
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // ""')
ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || echo "")

# Fetch board fields
BOARD=$(bash "$SCRIPT_DIR/read-board.sh" 2>/dev/null || echo '{"cards":[]}')
CARD_JSON=$(echo "$BOARD" | jq --argjson c "$CARD" '[.cards[] | select(.issue_number == $c)] | .[0] // {}')
HAS_UI=$(echo "$CARD_JSON" | jq -r '.fields.HasUIChanges // ""')
DESIGN_URL=$(echo "$CARD_JSON" | jq -r '.fields.DesignURL // ""')

CHECKS=()
FAILURES=()

# ── Check 1: Acceptance criteria present ─────────────────
if echo "$ISSUE_BODY" | grep -qiE '^\s*-\s*\[[ x]\]'; then
  CHECKS+=('{"name": "acceptance_criteria", "status": "pass"}')
else
  CHECKS+=('{"name": "acceptance_criteria", "status": "fail"}')
  FAILURES+=("No acceptance criteria checkboxes found in issue body")
fi

# ── Check 2: Edge cases mentioned ────────────────────────
if echo "$ISSUE_BODY" | grep -qiE 'empty.?state|error.?state|edge.?case|boundary|overflow|truncat'; then
  CHECKS+=('{"name": "edge_cases", "status": "pass"}')
else
  CHECKS+=('{"name": "edge_cases", "status": "warn"}')
  # Warning only — not all cards need explicit edge case mentions
fi

# ── Check 3: Scope defined ──────────────────────────────
if echo "$ISSUE_BODY" | grep -qiE 'scope|non.?goal|out of scope|not.?include'; then
  CHECKS+=('{"name": "scope_bounded", "status": "pass"}')
else
  CHECKS+=('{"name": "scope_bounded", "status": "warn"}')
fi

# ── Check 4: HasUIChanges field set ──────────────────────
if [[ -n "$HAS_UI" && "$HAS_UI" != "null" ]]; then
  CHECKS+=('{"name": "has_ui_changes_set", "status": "pass"}')
else
  CHECKS+=('{"name": "has_ui_changes_set", "status": "fail"}')
  FAILURES+=("HasUIChanges field not set on card")
fi

# ── Check 5: DesignURL set (if UI card) ─────────────────
if [[ "$HAS_UI" == "Yes" ]]; then
  if [[ -n "$DESIGN_URL" && "$DESIGN_URL" != "null" ]]; then
    CHECKS+=('{"name": "design_url", "status": "pass"}')
  else
    CHECKS+=('{"name": "design_url", "status": "fail"}')
    FAILURES+=("UI card missing DesignURL field")
  fi
else
  CHECKS+=('{"name": "design_url", "status": "skip"}')
fi

# ── Check 6: Mockup posted with correct URL format (if UI card) ────
# Require:
#   a) an <img src="..."> comment
#   b) the URL points at lh3.googleusercontent.com (the inline Stitch CDN)
#   c) the URL ends with =w800 for full-res (not the ~45KB default)
#
# These rules come from feedback_stitch_quality.md after 6/9 Designer
# runs on 2026-04-14 shipped missing or low-res mockups.
if [[ "$HAS_UI" == "Yes" ]]; then
  COMMENTS_WITH_IMG=$(echo "$ISSUE_JSON" | jq -r '.comments[].body' | grep -oE '<img src="[^"]+"' || true)

  if [[ -z "$COMMENTS_WITH_IMG" ]]; then
    CHECKS+=('{"name": "mockup_posted", "status": "fail"}')
    FAILURES+=("UI card has no <img src=\"...\"> mockup comment")
  else
    LH3_COUNT=$(echo "$COMMENTS_WITH_IMG" | grep -c 'lh3.googleusercontent.com' || true)
    W800_COUNT=$(echo "$COMMENTS_WITH_IMG" | grep -c '=w800' || true)

    if [[ "$LH3_COUNT" -eq 0 ]]; then
      CHECKS+=('{"name": "mockup_posted", "status": "fail"}')
      FAILURES+=("UI card has <img> but not pointing at lh3.googleusercontent.com — do NOT re-upload Stitch output, use the inline URL directly")
    elif [[ "$W800_COUNT" -eq 0 ]]; then
      CHECKS+=('{"name": "mockup_posted", "status": "fail"}')
      FAILURES+=("UI card mockup URL is missing the =w800 suffix, serving a low-res thumbnail instead of the full 528KB image")
    else
      CHECKS+=('{"name": "mockup_posted", "status": "pass"}')
    fi
  fi
else
  CHECKS+=('{"name": "mockup_posted", "status": "skip"}')
fi

# ── Determine readiness ─────────────────────────────────
FAIL_COUNT=${#FAILURES[@]}
READY=true
[[ "$FAIL_COUNT" -gt 0 ]] && READY=false

# ── Output JSON ──────────────────────────────────────────
CHECKS_JSON=$(printf '%s\n' "${CHECKS[@]}" | jq -s '.')
FAILURES_JSON=$(printf '%s\n' "${FAILURES[@]+"${FAILURES[@]}"}" | jq -R . | jq -s '.')

jq -n \
  --argjson card "$CARD" \
  --argjson ready "$READY" \
  --argjson checks "$CHECKS_JSON" \
  --argjson failures "$FAILURES_JSON" \
  '{card: $card, ready: $ready, checks: $checks, failures: $failures}'
