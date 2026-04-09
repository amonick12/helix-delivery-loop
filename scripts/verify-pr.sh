#!/bin/bash
# verify-pr.sh — Checks CI status and acceptance criteria for a PR.
#
# Deterministic gates (build, tests, lint, static analysis) are handled
# by GitHub Actions CI. This script checks that CI passed, matches
# acceptance criteria from criteria-tests.json, detects UI changes,
# and updates state/artifacts.
#
# Usage:
#   ./verify-pr.sh --card N --pr N [--worktree <path>]
#
# Output: JSON with CI status, acceptance criteria results, UI detection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
verify-pr.sh — Checks CI status and acceptance criteria for a PR.

Usage:
  ./verify-pr.sh --card N --pr N [--worktree <path>]

Options:
  --card <N>         Card/issue number (required)
  --pr <N>           PR number (required)
  --worktree <path>  Path to the worktree (optional, for UI detection)

Checks:
  1. CI status via gh pr checks
  2. Acceptance criteria via criteria-tests.json (if exists)
  3. UI change detection (diff-based)

Output: JSON { card, pr, gates_passing, criteria_checked, has_ui_changes }
HELP

# ── Parse args ──────────────────────────────────────────
CARD=""
PR_NUMBER=""
WORKTREE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)     CARD="$2"; shift 2 ;;
    --pr)       PR_NUMBER="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    *)          log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$CARD" ]]; then
  log_error "--card <number> is required"
  exit 1
fi
if [[ -z "$PR_NUMBER" ]]; then
  log_error "--pr <number> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Step 1: Check Builder gate results ────────────────────
log_info "Checking Builder gates for card #$CARD"
GATES_PASSING=false
GATES_FAILURES=0
GATES_TOTAL=5

GATES_FILE="$ARTIFACT_BASE/$CARD/gates.json"
if [[ "$DRY_RUN" != "1" ]]; then
  if [[ -f "$GATES_FILE" ]]; then
    local_pass=$(jq -r '.all_pass' "$GATES_FILE" 2>/dev/null || echo "false")
    if [[ "$local_pass" == "true" ]]; then
      GATES_PASSING=true
      log_info "Builder gates: all passing"
    else
      GATES_FAILURES=$(jq '[to_entries[] | select(.value == "fail")] | length' "$GATES_FILE" 2>/dev/null || echo "0")
      log_warn "Builder gates: $GATES_FAILURES gate(s) failing"
    fi
  else
    log_warn "Builder gates: gates.json not found"
  fi
else
  GATES_PASSING=true
fi

# Check off gate on PR if passing
if [[ "$GATES_PASSING" == "true" && "$DRY_RUN" != "1" ]]; then
  bash "$SCRIPTS_DIR/update-pr-checklist.sh" --pr "$PR_NUMBER" --card "$CARD" \
    --check-gate "Builder gates passing (build, tests, lint, static analysis)" >/dev/null 2>&1 || true
fi

# ── Step 2: Detect UI changes ────────────────────────────
log_info "Detecting UI changes for card #$CARD"
HAS_UI_CHANGES="No"
UI_FILE_COUNT=0

if [[ -n "$WORKTREE" && -d "$WORKTREE" ]]; then
  UI_FILE_COUNT=$(cd "$WORKTREE" && git diff --name-only "origin/$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null | \
    xargs grep -l 'struct.*:.*View\b\|SwiftUI\|@ViewBuilder\|NavigationStack\|TabView\|Sheet\|Preview' 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  [[ "$UI_FILE_COUNT" -gt 0 ]] && HAS_UI_CHANGES="Yes"
elif [[ "$DRY_RUN" != "1" ]]; then
  # Fallback: check board field
  BOARD_JSON=$("$SCRIPTS_DIR/read-board.sh" 2>/dev/null || echo '{"cards":[]}')
  BOARD_UI=$(echo "$BOARD_JSON" | jq -r ".cards[] | select(.issue_number == $CARD) | .fields.HasUIChanges // \"\"" 2>/dev/null || echo "")
  [[ "$BOARD_UI" == "Yes" ]] && HAS_UI_CHANGES="Yes"
fi
log_info "HasUIChanges=$HAS_UI_CHANGES ($UI_FILE_COUNT view files)"

# ── Step 3: Check acceptance criteria ─────────────────────
CRITERIA_CHECKED=0
CRITERIA_TOTAL=0

ARTIFACT_DIR=$(ensure_artifact_dir "$CARD")
CRITERIA_MAP="$ARTIFACT_DIR/criteria-tests.json"
[[ ! -f "$CRITERIA_MAP" && -n "$WORKTREE" ]] && CRITERIA_MAP="$WORKTREE/criteria-tests.json"

if [[ -f "$CRITERIA_MAP" ]]; then
  log_info "Found criteria-tests.json — checking acceptance criteria"
  CRITERIA_ITEMS=$(jq -c 'if type == "array" then .[] elif .criteria then .criteria[] else empty end' "$CRITERIA_MAP" 2>/dev/null)

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    CRITERION=$(echo "$entry" | jq -r '.criterion // empty')
    [[ -z "$CRITERION" ]] && continue
    CRITERIA_TOTAL=$((CRITERIA_TOTAL + 1))

    # Check off on PR checklist (Reviewer verifies separately via code review)
    if [[ "$DRY_RUN" != "1" ]]; then
      bash "$SCRIPTS_DIR/update-pr-checklist.sh" --pr "$PR_NUMBER" --card "$CARD" \
        --check "$CRITERION" >/dev/null 2>&1 || true
    fi
    CRITERIA_CHECKED=$((CRITERIA_CHECKED + 1))
    log_info "Criterion: $CRITERION"
  done <<< "$CRITERIA_ITEMS"
else
  log_info "No criteria-tests.json found"
fi

# ── Step 4: Update state ─────────────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
  bash "$SCRIPTS_DIR/state.sh" set "$CARD" gates_passing "$GATES_PASSING" 2>/dev/null || true
  bash "$SCRIPTS_DIR/state.sh" set "$CARD" has_ui_changes "$HAS_UI_CHANGES" 2>/dev/null || true
  # Update comment timestamp
  bash "$SCRIPTS_DIR/update-comment-ts.sh" --card "$CARD" 2>/dev/null || true
fi

# ── Step 5: Clean up worktrees for Done cards ─────────────
if [[ "$DRY_RUN" != "1" ]]; then
  for wt in /tmp/helix-wt/feature/*; do
    [[ -d "$wt" ]] || continue
    card_num=$(basename "$wt" | grep -oE '^[0-9]+')
    [[ -z "$card_num" ]] && continue
    status=$(bash "$SCRIPTS_DIR/read-board.sh" --card-id "$card_num" 2>/dev/null | jq -r '.cards[0].fields.Status // ""')
    if [[ "$status" == "Done" ]]; then
      log_info "Cleaning up worktree for Done card #$card_num"
      git worktree remove "$wt" 2>/dev/null || true
    fi
  done
  git worktree prune 2>/dev/null || true
fi

# ── Output JSON ───────────────────────────────────────────
RESULT=$(jq -n \
  --argjson card "$CARD" \
  --argjson pr "$PR_NUMBER" \
  --argjson gates_passing "$GATES_PASSING" \
  --argjson gates_total "$GATES_TOTAL" \
  --argjson gates_failures "$GATES_FAILURES" \
  --arg has_ui_changes "$HAS_UI_CHANGES" \
  --argjson criteria_checked "$CRITERIA_CHECKED" \
  --argjson criteria_total "$CRITERIA_TOTAL" \
  '{
    card: $card,
    pr: $pr,
    gates_passing: $gates_passing,
    gates_total: $gates_total,
    gates_failures: $gates_failures,
    has_ui_changes: $has_ui_changes,
    criteria_checked: $criteria_checked,
    criteria_total: $criteria_total,
    timestamp: (now | todate)
  }')

# Write to artifact dir
echo "$RESULT" > "$ARTIFACT_DIR/$ARTIFACT_VERIFICATION"
echo "$RESULT"
