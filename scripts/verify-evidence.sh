#!/bin/bash
# verify-evidence.sh — Check that a PR has required visual evidence before tests-passed.
#
# Usage:
#   ./verify-evidence.sh --pr 42 --card 137
#
# Output: JSON { "eligible": true/false, "missing": [...], "found": [...] }
#
# Env:
#   DRY_RUN=1   Use mock data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
verify-evidence.sh — Check that a PR has required visual evidence.

Usage:
  ./verify-evidence.sh --pr 42 --card 137

Options:
  --pr <N>     PR number (required)
  --card <N>   Card/issue number (required)

Checks:
  - If HasUIChanges=No → eligible=true (no evidence needed)
  - If HasUIChanges=Yes, checks PR comments for:
    - Screenshot evidence (image URLs)
    - Recording evidence (.mov/.mp4 URLs)
    - Side-by-side table (before/after comparison)

Output: JSON { "eligible": true/false, "missing": [...], "found": [...] }

Env:
  DRY_RUN=1   Use mock data
HELP

# ── Parse args ─────────────────────────────────────────
PR_NUMBER=""
CARD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)   PR_NUMBER="$2"; shift 2 ;;
    --card) CARD="$2"; shift 2 ;;
    *)      log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  log_error "--pr <number> is required"
  exit 1
fi
if [[ -z "$CARD" ]]; then
  log_error "--card <number> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Auto-detect UI changes from PR diff ──────────────
HAS_UI_CHANGES="No"
if [[ "$DRY_RUN" == "1" ]]; then
  HAS_UI_CHANGES="${MOCK_HAS_UI_CHANGES:-Yes}"
else
  # Find worktree for this card
  WORKTREE=""
  for wt in /tmp/helix-wt/feature/${CARD}-*; do
    [[ -d "$wt" ]] && WORKTREE="$wt" && break
  done

  if [[ -n "$WORKTREE" ]]; then
    UI_FILE_COUNT=$(cd "$WORKTREE" && git diff --name-only "origin/$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null | \
      xargs grep -l 'struct.*:.*View\b\|SwiftUI\|@ViewBuilder\|NavigationStack\|TabView\|Sheet\|Preview' 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    [[ "$UI_FILE_COUNT" -gt 0 ]] && HAS_UI_CHANGES="Yes"
    log_info "Auto-detected HasUIChanges=$HAS_UI_CHANGES ($UI_FILE_COUNT view files in PR diff)"
  else
    # Fallback: check board field
    BOARD_JSON=$("$SCRIPT_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null || echo '{"cards":[]}')
    BOARD_UI=$(echo "$BOARD_JSON" | jq -r ".cards[] | select(.issue_number == $CARD) | .fields.HasUIChanges // \"\"" 2>/dev/null || echo "")
    [[ "$BOARD_UI" == "Yes" ]] && HAS_UI_CHANGES="Yes"
  fi
fi

# If no UI changes, evidence is not required
if [[ "$HAS_UI_CHANGES" == "No" ]]; then
  log_info "Card #$CARD has no UI changes — no visual evidence required"
  jq -n '{eligible: true, missing: [], found: ["no_ui_changes"]}'
  exit 0
fi

# ── Fetch PR comments ─────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  PR_COMMENTS="${MOCK_PR_COMMENTS:-[]}"
else
  PR_COMMENTS=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json comments -q '.comments[].body' 2>/dev/null || echo "")
fi

# Also check PR body
if [[ "$DRY_RUN" == "1" ]]; then
  PR_BODY="${MOCK_PR_BODY:-}"
else
  PR_BODY=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body -q '.body' 2>/dev/null || echo "")
fi

ALL_TEXT="$PR_BODY
$PR_COMMENTS"

# ── Check for required evidence ───────────────────────
FOUND="[]"
MISSING="[]"

# Check 1: Screenshot evidence — must have actual images posted (![alt](url) or <img src="url">)
# The word "screenshot" in text is NOT sufficient.
MD_IMAGES=$(echo "$ALL_TEXT" | grep -c '!\[' 2>/dev/null || echo "0")
MD_IMAGES="${MD_IMAGES//[^0-9]/}"
MD_IMAGES="${MD_IMAGES:-0}"
HTML_IMAGES=$(echo "$ALL_TEXT" | grep -c '<img ' 2>/dev/null || echo "0")
HTML_IMAGES="${HTML_IMAGES//[^0-9]/}"
HTML_IMAGES="${HTML_IMAGES:-0}"
IMAGE_COUNT=$(( MD_IMAGES + HTML_IMAGES ))
if [[ "$IMAGE_COUNT" -gt 0 ]]; then
  FOUND=$(echo "$FOUND" | jq --argjson n "$IMAGE_COUNT" '. + ["screenshots (\($n) images)"]')
  log_info "Found: $IMAGE_COUNT actual images ($MD_IMAGES markdown, $HTML_IMAGES html)"
else
  MISSING=$(echo "$MISSING" | jq '. + ["screenshots — no images found in any PR comment (use <img src=url width=300> or ![](url))"]')
  log_warn "Missing: screenshot evidence — no actual images posted (text mentions don't count)"
fi

# Check 2: Recording evidence — must have ACTUAL .mov or .mp4 file URL, not just the word "recording"
if echo "$ALL_TEXT" | grep -qE 'https?://[^ ]+\.(mov|mp4)'; then
  FOUND=$(echo "$FOUND" | jq '. + ["recordings"]')
  log_info "Found: recording file URL"
else
  MISSING=$(echo "$MISSING" | jq '. + ["recordings — no .mov/.mp4 URL found in any PR comment"]')
  log_warn "Missing: recording evidence — no video file URL posted"
fi

# Check 3: Side-by-side table — must have a markdown table with Before and After columns
if echo "$ALL_TEXT" | grep -qE '\|.*[Bb]efore.*\|.*[Aa]fter.*\|'; then
  FOUND=$(echo "$FOUND" | jq '. + ["before_after_table"]')
  log_info "Found: before/after comparison table"
else
  MISSING=$(echo "$MISSING" | jq '. + ["before_after_table — no markdown table with Before|After columns"]')
  log_warn "Missing: before/after comparison table"
fi

# Check 4: Visual QA pass — vision API must have verified screenshots against design mockup
if echo "$ALL_TEXT" | grep -qiE 'Visual QA.*PASS'; then
  FOUND=$(echo "$FOUND" | jq '. + ["visual_qa_pass"]')
  log_info "Found: Visual QA PASS from vision API verification"
else
  MISSING=$(echo "$MISSING" | jq '. + ["visual_qa_pass — no Visual QA PASS from vision API found in any PR comment"]')
  log_warn "Missing: Visual QA PASS — screenshots must be verified by vision API before approval"
fi

# ── Determine eligibility ─────────────────────────────
MISSING_COUNT=$(echo "$MISSING" | jq 'length')
ELIGIBLE=false
if [[ "$MISSING_COUNT" -eq 0 ]]; then
  ELIGIBLE=true
fi

# ── Output JSON ───────────────────────────────────────
jq -n \
  --argjson eligible "$ELIGIBLE" \
  --argjson missing "$MISSING" \
  --argjson found "$FOUND" \
  '{eligible: $eligible, missing: $missing, found: $found}'
