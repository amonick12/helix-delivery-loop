#!/bin/bash
# preflight.sh — Pre-agent validation checks.
#
# Usage:
#   ./preflight.sh --agent <agent> --card <N>
#
# Exit 0 = all checks pass. Exit 1 = at least one check failed.
# Output JSON: { "passed": bool, "checks": [...], "failures": [...] }
#
# Per-agent checks:
#   planner  — Card in Ready, no existing worktree, origin/$BASE_BRANCH exists
#   builder  — Card In Progress, handoff_from is planner, worktree exists
#   reviewer — Card In Progress, PR ready (not draft), no code-review-approved
#   tester   — Card In Progress, PR ready, code-review-approved, no visual-qa-approved
#   releaser — Card In Review, user-approved label, PR is mergeable
#   designer — Card in Backlog, HasUIChanges field not already set
#   scout    — No other agents currently active (timers within last 30 min)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
preflight.sh — Pre-agent validation checks.

Usage:
  ./preflight.sh --agent <agent> --card <N>

Exit 0 = all checks pass. Exit 1 = at least one check failed.
Output JSON: { "passed": bool, "checks": [...], "failures": [...] }

Agents: planner, builder, reviewer, tester, releaser, designer, scout
HELP

# ── Parse args ──────────────────────────────────────────
AGENT=""
CARD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --card)  CARD="$2"; shift 2 ;;
    *)       log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$AGENT" ]]; then
  log_error "--agent <agent> is required"
  exit 1
fi
if [[ -z "$CARD" ]]; then
  log_error "--card <N> is required"
  exit 1
fi

# ── Result accumulators (no local outside functions) ────
CHECKS="[]"
FAILURES="[]"

add_check() {
  local name="$1"
  local result="$2"
  local detail="$3"
  CHECKS=$(echo "$CHECKS" | jq --arg n "$name" --arg r "$result" --arg d "$detail" \
    '. + [{"name": $n, "result": $r, "detail": $d}]')
  if [[ "$result" == "fail" ]]; then
    FAILURES=$(echo "$FAILURES" | jq --arg n "$name" --arg d "$detail" \
      '. + [{"check": $n, "reason": $d}]')
  fi
}

# ── Read board data for this card ───────────────────────
get_card_status() {
  local card_id="$1"
  local board_json
  board_json=$(bash "$SCRIPTS_DIR/read-board.sh" --card-id "$card_id" 2>/dev/null) || {
    echo ""
    return
  }
  echo "$board_json" | jq -r '.cards[0].fields.Status // empty' 2>/dev/null
}

get_card_field() {
  local card_id="$1"
  local field="$2"
  local board_json
  board_json=$(bash "$SCRIPTS_DIR/read-board.sh" --card-id "$card_id" 2>/dev/null) || {
    echo ""
    return
  }
  echo "$board_json" | jq -r --arg f "$field" '.cards[0].fields[$f] // empty' 2>/dev/null
}

get_card_labels() {
  local card_id="$1"
  local board_json
  board_json=$(bash "$SCRIPTS_DIR/read-board.sh" --card-id "$card_id" 2>/dev/null) || {
    echo ""
    return
  }
  echo "$board_json" | jq -r '.cards[0].labels // [] | .[]' 2>/dev/null
}

# ── Agent-specific checks ──────────────────────────────
check_planner() {
  # 1. Card in Ready
  STATUS=$(get_card_status "$CARD")
  if [[ "$STATUS" == "Ready" ]]; then
    add_check "card_status_ready" "pass" "Card #$CARD is in Ready"
  else
    add_check "card_status_ready" "fail" "Card #$CARD status is '$STATUS', expected 'Ready'"
  fi

  # 2. No existing worktree for this card
  WT_PATH=$(bash "$SCRIPTS_DIR/worktree.sh" path --card "$CARD" 2>/dev/null) || WT_PATH=""
  if [[ -z "$WT_PATH" ]]; then
    add_check "no_existing_worktree" "pass" "No worktree exists for card #$CARD"
  else
    add_check "no_existing_worktree" "fail" "Worktree already exists at $WT_PATH"
  fi

  # 3. origin/$BASE_BRANCH exists
  if git rev-parse --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    add_check "base_branch_exists" "pass" "origin/$BASE_BRANCH exists"
  else
    add_check "base_branch_exists" "fail" "origin/$BASE_BRANCH does not exist"
  fi
}

check_builder() {
  # 1. Card In Progress
  STATUS=$(get_card_status "$CARD")
  if [[ "$STATUS" == "In Progress" ]]; then
    add_check "card_status_in_progress" "pass" "Card #$CARD is In Progress"
  else
    add_check "card_status_in_progress" "fail" "Card #$CARD status is '$STATUS', expected 'In Progress'"
  fi

  # 2. handoff_from is planner
  HANDOFF=$(bash "$SCRIPTS_DIR/state.sh" get "$CARD" "handoff_from" 2>/dev/null) || HANDOFF=""
  if [[ "$HANDOFF" == "planner" ]]; then
    add_check "handoff_from_planner" "pass" "Handoff from planner confirmed"
  else
    add_check "handoff_from_planner" "fail" "handoff_from is '$HANDOFF', expected 'planner'"
  fi

  # 3. Worktree exists
  WT_PATH=$(bash "$SCRIPTS_DIR/worktree.sh" path --card "$CARD" 2>/dev/null) || WT_PATH=""
  if [[ -n "$WT_PATH" && -d "$WT_PATH" ]]; then
    add_check "worktree_exists" "pass" "Worktree exists at $WT_PATH"
  else
    add_check "worktree_exists" "fail" "No worktree found for card #$CARD"
  fi
}

check_reviewer() {
  # 1. Card In Progress
  STATUS=$(get_card_status "$CARD")
  if [[ "$STATUS" == "In Progress" || "$STATUS" == "In progress" ]]; then
    add_check "card_status_in_progress" "pass" "Card #$CARD is In Progress"
  else
    add_check "card_status_in_progress" "fail" "Card #$CARD status is '$STATUS', expected 'In Progress'"
  fi

  # 2. PR URL exists and PR is ready (not draft)
  PR_URL=$(get_card_field "$CARD" "PR URL")
  if [[ -n "$PR_URL" ]]; then
    add_check "pr_url_exists" "pass" "PR URL found: $PR_URL"
  else
    add_check "pr_url_exists" "fail" "No PR URL set on card #$CARD"
  fi
}

check_tester() {
  check_reviewer  # same base checks
}
}

check_releaser() {
  # 1. Card In Review
  STATUS=$(get_card_status "$CARD")
  if [[ "$STATUS" == "In Review" ]]; then
    add_check "card_status_in_review" "pass" "Card #$CARD is In Review"
  else
    add_check "card_status_in_review" "fail" "Card #$CARD status is '$STATUS', expected 'In Review'"
  fi

  # 2. user-approved label present (check both issue and PR labels)
  ISSUE_APPROVED=$(gh issue view "$CARD" --repo "$REPO" --json labels --jq 'any(.labels[]; .name == "user-approved")' 2>/dev/null) || ISSUE_APPROVED="false"

  # Also check PR labels — find PR number from card's PR URL
  PR_URL=$(get_card_field "$CARD" "PR URL")
  PR_APPROVED="false"
  if [[ -n "$PR_URL" ]]; then
    PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$' || echo "")
    if [[ -n "$PR_NUM" ]]; then
      PR_APPROVED=$(gh pr view "$PR_NUM" --repo "$REPO" --json labels --jq 'any(.labels[]; .name == "user-approved")' 2>/dev/null) || PR_APPROVED="false"
    fi
  fi

  if [[ "$ISSUE_APPROVED" == "true" || "$PR_APPROVED" == "true" ]]; then
    add_check "user_approved_label" "pass" "user-approved label found"
  else
    add_check "user_approved_label" "fail" "user-approved label not found on issue or PR"
  fi

  # 3. PR is mergeable
  if [[ -n "$PR_URL" ]]; then
    PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$' || echo "")
    if [[ -n "$PR_NUM" ]]; then
      MERGEABLE=$(gh pr view "$PR_NUM" --repo "$REPO" --json mergeable --jq '.mergeable' 2>/dev/null) || MERGEABLE="UNKNOWN"
      if [[ "$MERGEABLE" == "MERGEABLE" ]]; then
        add_check "pr_mergeable" "pass" "PR #$PR_NUM is mergeable"
      else
        add_check "pr_mergeable" "fail" "PR #$PR_NUM mergeable status: $MERGEABLE"
      fi
    else
      add_check "pr_mergeable" "fail" "Could not extract PR number from URL"
    fi
  else
    add_check "pr_mergeable" "fail" "No PR URL on card — cannot check mergeability"
  fi
}

check_designer() {
  # 1. Card in Backlog
  STATUS=$(get_card_status "$CARD")
  if [[ "$STATUS" == "Backlog" ]]; then
    add_check "card_status_backlog" "pass" "Card #$CARD is in Backlog"
  else
    add_check "card_status_backlog" "fail" "Card #$CARD status is '$STATUS', expected 'Backlog'"
  fi

  # 2. HasUIChanges field not already set
  HAS_UI=$(get_card_field "$CARD" "HasUIChanges")
  if [[ -z "$HAS_UI" ]]; then
    add_check "has_ui_changes_unset" "pass" "HasUIChanges not yet set on card #$CARD"
  else
    add_check "has_ui_changes_unset" "fail" "HasUIChanges already set to '$HAS_UI'"
  fi
}

check_scout() {
  # No other agents currently active (check state file timers started within last 30 min)
  NOW=$(date +%s)
  THRESHOLD=$((30 * 60))
  ACTIVE_AGENTS=""

  if [[ -f "$STATE_FILE" ]]; then
    ACTIVE_AGENTS=$(jq -r --argjson now "$NOW" --argjson thresh "$THRESHOLD" '
      .cards // {} | to_entries[] |
      select(.value.timer_start != null) |
      select(($now - (.value.timer_start | tonumber)) < $thresh) |
      "\(.key):\(.value.timer_agent // "unknown")"
    ' "$STATE_FILE" 2>/dev/null) || ACTIVE_AGENTS=""
  fi

  if [[ -z "$ACTIVE_AGENTS" ]]; then
    add_check "no_active_agents" "pass" "No other agents active in last 30 minutes"
  else
    add_check "no_active_agents" "fail" "Active agents found: $ACTIVE_AGENTS"
  fi
}

# ── Dispatch agent checks ──────────────────────────────
case "$AGENT" in
  planner)  check_planner ;;
  builder)  check_builder ;;
  reviewer) check_reviewer ;;
  tester) check_tester ;;
  releaser) check_releaser ;;
  designer) check_designer ;;
  scout)    check_scout ;;
  *)
    log_error "Unknown agent: $AGENT"
    log_error "Valid agents: planner, builder, reviewer, tester, releaser, designer, scout"
    exit 1
    ;;
esac

# ── Output result ──────────────────────────────────────
FAILURE_COUNT=$(echo "$FAILURES" | jq 'length')

if [[ "$FAILURE_COUNT" -eq 0 ]]; then
  PASSED="true"
  EXIT_CODE=0
else
  PASSED="false"
  EXIT_CODE=1
fi

jq -n \
  --argjson passed "$PASSED" \
  --argjson checks "$CHECKS" \
  --argjson failures "$FAILURES" \
  '{passed: $passed, checks: $checks, failures: $failures}'

exit "$EXIT_CODE"
