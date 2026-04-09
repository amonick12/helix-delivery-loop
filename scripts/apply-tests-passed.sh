#!/bin/bash
# apply-tests-passed.sh — Single enforcement script for tests-passed label.
#
# Usage:
#   ./apply-tests-passed.sh --pr 42 --card 137
#
# Internally:
#   1. Calls update-pr-checklist.sh → checks all_checked
#   2. If HasUIChanges=Yes: calls verify-evidence.sh → checks eligible
#   3. If both pass: applies "tests-passed" label
#   4. If either fails: prints what's missing, does NOT apply label
#
# Output: JSON { approved, reason, checklist_checked, checklist_total, evidence_eligible }
#
# Env:
#   DRY_RUN=1   Skip gh calls, print what would happen

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
apply-tests-passed.sh — Single enforcement script for tests-passed label.

Usage:
  ./apply-tests-passed.sh --pr 42 --card 137

Options:
  --pr <N>     PR number (required)
  --card <N>   Card/issue number (required)

Steps:
  1. Calls update-pr-checklist.sh → checks all_checked
  2. If HasUIChanges=Yes: calls verify-evidence.sh → checks eligible
  3. If both pass: applies "tests-passed" label via gh
  4. If either fails: prints what's missing, does NOT apply label

Output: JSON { approved, reason, checklist_checked, checklist_total, evidence_eligible }

Env:
  DRY_RUN=1   Skip gh calls, print what would happen
HELP

# ── Parse args ──────────────────────────────────────────
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

# ── Step 1: Check PR checklist ──────────────────────────
log_info "Step 1: Checking PR checklist for PR #$PR_NUMBER, card #$CARD"
CHECKLIST_JSON=$(bash "$SCRIPT_DIR/update-pr-checklist.sh" --pr "$PR_NUMBER" --card "$CARD" 2>/dev/null | grep -A1000 '^{')

ALL_CHECKED=$(echo "$CHECKLIST_JSON" | jq -r '.all_checked')
CHECKLIST_CHECKED=$(echo "$CHECKLIST_JSON" | jq -r '.checked')
CHECKLIST_TOTAL=$(echo "$CHECKLIST_JSON" | jq -r '.total')
UNCHECKED=$(echo "$CHECKLIST_JSON" | jq -r '.unchecked')

if [[ "$ALL_CHECKED" != "true" ]]; then
  log_warn "Checklist not complete: $CHECKLIST_CHECKED/$CHECKLIST_TOTAL checked"
  log_warn "Unchecked items: $(echo "$UNCHECKED" | jq -r 'join(", ")')"
fi

# ── Step 2: Check visual evidence (if UI card) ─────────
EVIDENCE_ELIGIBLE=true
HAS_UI_CHANGES="No"

if [[ "$DRY_RUN" == "1" ]]; then
  HAS_UI_CHANGES="${MOCK_HAS_UI_CHANGES:-No}"
else
  # Auto-detect UI changes from PR diff (same logic as verify-pr.sh)
  PR_BRANCH=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
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
    BOARD_JSON=$("$SCRIPT_DIR/read-board.sh" 2>/dev/null || echo '{"cards":[]}')
    BOARD_UI=$(echo "$BOARD_JSON" | jq -r ".cards[] | select(.issue_number == $CARD) | .fields.HasUIChanges // \"\"" 2>/dev/null || echo "")
    [[ "$BOARD_UI" == "Yes" ]] && HAS_UI_CHANGES="Yes"
  fi
fi

if [[ "$HAS_UI_CHANGES" == "Yes" ]]; then
  log_info "Step 2: Card has UI changes — checking visual evidence"
  if [[ -f "$SCRIPT_DIR/verify-evidence.sh" ]]; then
    EVIDENCE_JSON=$(bash "$SCRIPT_DIR/verify-evidence.sh" --pr "$PR_NUMBER" --card "$CARD" 2>/dev/null || echo '{"eligible": false, "missing": ["verify-evidence.sh failed"]}')
    EVIDENCE_ELIGIBLE=$(echo "$EVIDENCE_JSON" | jq -r '.eligible')
    if [[ "$EVIDENCE_ELIGIBLE" != "true" ]]; then
      EVIDENCE_MISSING=$(echo "$EVIDENCE_JSON" | jq -r '.missing | join(", ")')
      log_warn "Evidence incomplete: $EVIDENCE_MISSING"
    fi
  else
    # Check for screenshot/recording comments on PR as fallback
    SCREENSHOT_COUNT=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json comments \
      --jq '[.comments[].body | select(test("screenshot|recording|Visual QA.*PASS|Simulator Visual Evidence"; "i"))] | length' 2>/dev/null || echo "0")
    if [[ "$SCREENSHOT_COUNT" -eq 0 ]]; then
      EVIDENCE_ELIGIBLE=false
      log_warn "No visual evidence found on PR #$PR_NUMBER (no screenshots, recordings, or Visual QA pass)"
    fi
  fi
else
  log_info "Step 2: Card has no UI changes — skipping evidence check"
fi

# ── Step 3: Apply label or report failure ───────────────
APPROVED=false
REASON=""

if [[ "$ALL_CHECKED" == "true" && "$EVIDENCE_ELIGIBLE" == "true" ]]; then
  APPROVED=true
  REASON="All $CHECKLIST_TOTAL checklist items checked, evidence requirements met"
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[DRY_RUN] Would apply tests-passed label to PR #$PR_NUMBER"
  else
    # Idempotency: check if label already applied
    ALREADY_APPROVED=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json labels --jq 'any(.labels[]; .name == "tests-passed")' 2>/dev/null || echo "false")
    if [[ "$ALREADY_APPROVED" == "true" ]]; then
      log_info "tests-passed label already present on PR #$PR_NUMBER"
    else
      gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "tests-passed"
      log_info "Applied tests-passed label to PR #$PR_NUMBER"
    fi
    # Move card to In Review when tests-passed is applied
    bash "$SCRIPT_DIR/move-card.sh" --issue "$CARD" --to "In review" 2>/dev/null || true
    log_info "Moved card #$CARD to In review"
  fi
else
  REASONS=()
  if [[ "$ALL_CHECKED" != "true" ]]; then
    REASONS+=("Checklist incomplete: $CHECKLIST_CHECKED/$CHECKLIST_TOTAL checked")
  fi
  if [[ "$EVIDENCE_ELIGIBLE" != "true" ]]; then
    REASONS+=("Visual evidence missing")
  fi
  REASON=$(IFS='; '; echo "${REASONS[*]}")
  log_warn "NOT applying tests-passed: $REASON"
fi

# ── Output JSON ─────────────────────────────────────────
jq -n \
  --argjson approved "$APPROVED" \
  --arg reason "$REASON" \
  --argjson checklist_checked "$CHECKLIST_CHECKED" \
  --argjson checklist_total "$CHECKLIST_TOTAL" \
  --argjson evidence_eligible "$EVIDENCE_ELIGIBLE" \
  '{
    approved: $approved,
    reason: $reason,
    checklist_checked: $checklist_checked,
    checklist_total: $checklist_total,
    evidence_eligible: $evidence_eligible
  }'
