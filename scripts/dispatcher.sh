#!/bin/bash
# dispatcher.sh — Deterministic dispatch: reads board + state, outputs one JSON decision.
#
# Usage:
#   ./dispatcher.sh              # Dispatch highest-priority action
#   ./dispatcher.sh --dry-run    # Show decision without executing
#
# Output: JSON with agent, card, reason, model, skipped[]
# No LLM. Pure jq logic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
dispatcher.sh — Deterministic dispatch logic for the delivery loop.

Usage:
  ./dispatcher.sh              # Dispatch highest-priority action
  ./dispatcher.sh --dry-run    # Show decision without executing

Output: JSON with agent, card, reason, model, skipped[]
HELP

DRY_RUN=false
MULTI=false
SKIP_CARDS="[]"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --multi) MULTI=true; shift ;;
    --skip-cards) SKIP_CARDS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Load board ───────────────────────────────────────────
if [[ -n "${BOARD_OVERRIDE:-}" && -f "${BOARD_OVERRIDE:-}" ]]; then
  BOARD=$(cat "$BOARD_OVERRIDE")
else
  BOARD=$(bash "$SCRIPTS_DIR/read-board.sh")
fi

# ── Load state ───────────────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
  STATE=$(cat "$STATE_FILE")
else
  STATE='{"cards":{}}'
fi

SKIPPED="[]"

# ── In-Flight State (for --multi parallel dispatch) ─────
IN_FLIGHT="[]"
IN_FLIGHT_CARDS="[]"
SIM_IN_USE=false
if [[ -f "$SCRIPTS_DIR/state.sh" ]]; then
  IN_FLIGHT=$(bash "$SCRIPTS_DIR/state.sh" list-inflight 2>/dev/null || echo "[]")
  IN_FLIGHT_CARDS=$(echo "$IN_FLIGHT" | jq '[.[].card]')
  SIM_IN_USE=$(echo "$IN_FLIGHT" | jq 'any(.[]; .needs_simulator == true)')
fi

# Merge skip-cards with in-flight cards for filtering
ALL_SKIP_CARDS=$(echo "$SKIP_CARDS $IN_FLIGHT_CARDS" | jq -s '.[0] + .[1] | unique')

# Check if a card should be skipped (in-flight or explicitly skipped)
is_card_skipped() {
  local card_id="$1"
  echo "$ALL_SKIP_CARDS" | jq -e --arg c "$card_id" 'any(.[]; tostring == $c)' > /dev/null 2>&1
}

# ── Helpers ──────────────────────────────────────────────

# Sort cards by priority (P0>P1>P2>P3) then by issue number (oldest first)
sort_by_priority() {
  jq 'sort_by(
    (if .fields.Priority == "P0" then 0
     elif .fields.Priority == "P1" then 1
     elif .fields.Priority == "P2" then 2
     elif .fields.Priority == "P3" then 3
     else 4 end),
    .issue_number
  )'
}

# Filter out blocked and dead-lettered cards, adding them to SKIPPED
filter_blocked() {
  local cards="$1"
  local blocked
  blocked=$(echo "$cards" | jq '[.[] | select(
    (.fields.BlockedReason // "") != ""
  )]')
  local dead_lettered
  dead_lettered=$(echo "$cards" | jq '[.[] | select(
    any(.labels[]; . == "dead-letter")
  )]')
  local label_blocked
  label_blocked=$(echo "$cards" | jq '[.[] | select(
    any(.labels[]; . == "blocked")
  )]')

  # Unapproved epics: have "epic" label but NOT "epic-approved"
  local unapproved_epics
  unapproved_epics=$(echo "$cards" | jq '[.[] | select(
    any(.labels[]; . == "epic") and (any(.labels[]; . == "epic-approved") | not)
  )]')

  # Add all blocked types to skipped list
  local new_skipped
  new_skipped=$(echo "$blocked" | jq '[.[] | {card: .issue_number, reason: ("Blocked: " + .fields.BlockedReason)}]')
  local dl_skipped
  dl_skipped=$(echo "$dead_lettered" | jq '[.[] | {card: .issue_number, reason: "Dead-lettered: remove dead-letter label to retry"}]')
  local lb_skipped
  lb_skipped=$(echo "$label_blocked" | jq '[.[] | {card: .issue_number, reason: "Blocked: depends on another PR"}]')
  local epic_skipped
  epic_skipped=$(echo "$unapproved_epics" | jq '[.[] | {card: .issue_number, reason: "Epic not approved: add epic-approved label to proceed"}]')
  SKIPPED=$(echo "$SKIPPED $new_skipped $dl_skipped $lb_skipped $epic_skipped" | jq -s '.[0] + .[1] + .[2] + .[3] + .[4]')

  # Return unblocked, not dead-lettered, not label-blocked, not unapproved epic
  echo "$cards" | jq '[.[] | select(
    (.fields.BlockedReason // "") == "" and
    (any(.labels[]; . == "dead-letter") | not) and
    (any(.labels[]; . == "blocked") | not) and
    ((any(.labels[]; . == "epic") | not) or any(.labels[]; . == "epic-approved"))
  )]'
}

# Get card state from state file
card_state() {
  local card_id="$1"
  echo "$STATE" | jq -r --arg c "$card_id" '.cards[$c] // {}'
}

# Output decision JSON
decide() {
  local agent="$1" card="$2" reason="$3" model="$4"
  jq -n \
    --arg agent "$agent" \
    --argjson card "$card" \
    --arg reason "$reason" \
    --arg model "$model" \
    --argjson skipped "$SKIPPED" \
    '{agent: $agent, card: $card, reason: $reason, model: $model, skipped: $skipped}'
}

# Model for agent (from config)
model_for() {
  local agent="$1"
  local card_id="${2:-}"
  local is_rework=false

  if [[ -n "$card_id" ]]; then
    local rework_target
    rework_target=$(echo "$STATE" | jq -r --arg c "$card_id" '.cards[$c].rework_target // ""')
    [[ -n "$rework_target" ]] && is_rework=true
  fi

  case "$agent" in
    scout)      echo "$MODEL_SCOUT" ;;
    maintainer) echo "$MODEL_MAINTAINER" ;;
    designer)   echo "$MODEL_DESIGNER" ;;
    planner)    echo "$MODEL_PLANNER" ;;
    builder)    echo "$MODEL_BUILDER" ;;
    reviewer)   echo "${MODEL_REVIEWER:-opus}" ;;
    tester)     echo "${MODEL_TESTER:-sonnet}" ;;
    releaser)   echo "$MODEL_RELEASER" ;;
    *)          echo "sonnet" ;;
  esac
}

# ── Count cards by status ────────────────────────────────
in_progress_count() {
  echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In progress")] | length'
}

in_review_count() {
  echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In review")] | length'
}

# ── Rule 1: Any active card with new user comment → Builder ──────
# User PR comments requesting changes route to Builder (the agent that modifies code).
# Reviewer/Tester are review-only and never touch code.
rule_1_comment_response() {
  # Check both In Review AND In Progress cards for new user comments
  local active_cards
  active_cards=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In review" or .fields.Status == "In progress")]')
  active_cards=$(filter_blocked "$active_cards")

  local count
  count=$(echo "$active_cards" | jq 'length')
  [[ "$count" -eq 0 ]] && return 1

  # Check each card for new comments since last check
  while IFS= read -r card_json; do
    local card_id
    card_id=$(echo "$card_json" | jq -r '.issue_number')
    local last_check
    last_check=$(echo "$STATE" | jq -r --arg c "$card_id" '.cards[$c].last_comment_check // "1970-01-01T00:00:00Z"')

    # Check board-embedded recent comments
    local has_new
    has_new=$(echo "$card_json" | jq -r --arg lc "$last_check" '
      [.recent_comments[] | select(.created > $lc and .author != "github-actions[bot]")] | length > 0
    ' 2>/dev/null || echo "false")

    # Also check PR comments directly via gh (more reliable than board JSON)
    if [[ "$has_new" != "true" ]]; then
      local pr_url
      pr_url=$(echo "$card_json" | jq -r '.fields["PR URL"] // ""')
      if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
        local pr_num
        pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
        if [[ -n "$pr_num" ]]; then
          local pr_comments
          pr_comments=$(gh pr view "$pr_num" --repo "$REPO" --json comments --jq "[.comments[] | select(.createdAt > \"$last_check\") | select(.author.login != \"github-actions[bot]\") | select(.body | test(\"$AGENT_COMMENT_FILTER\") | not)] | length" 2>/dev/null || echo "0")
          [[ "$pr_comments" -gt 0 ]] && has_new="true"
        fi
      fi
    fi

    if [[ "$has_new" == "true" ]]; then
      local comment_source="issue"
      [[ -n "${pr_num:-}" ]] && comment_source="PR #$pr_num"

      # Check if the new comment is a "deploy" command → route to Releaser for TestFlight
      local is_deploy=false
      if [[ -n "${pr_num:-}" ]]; then
        local deploy_comment
        deploy_comment=$(gh pr view "$pr_num" --repo "$REPO" --json comments \
          --jq "[.comments[] | select(.createdAt > \"$last_check\") | select(.author.login != \"github-actions[bot]\") | select(.body | test(\"^deploy$\"; \"i\"))] | length" 2>/dev/null || echo "0")
        [[ "$deploy_comment" -gt 0 ]] && is_deploy=true
      fi

      # Update last_comment_check now so subsequent dispatch cycles don't re-detect the same comment
      bash "$SCRIPTS_DIR/state.sh" set "$card_id" last_comment_check "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" 2>/dev/null || true

      if [[ "$is_deploy" == "true" ]]; then
        local model
        model=$(model_for releaser "$card_id")
        decide "releaser" "$card_id" "Card #$card_id: user commented 'deploy' on $comment_source — routing to Releaser for TestFlight" "$model"
      else
        local model
        model=$(model_for builder "$card_id")
        decide "builder" "$card_id" "Card #$card_id: user comment on $comment_source — routing to Builder for changes" "$model"
      fi
      return 0
    fi
  done < <(echo "$active_cards" | jq -c '.[]')

  return 1
}

# ── Rule 2: In Review + user-approved → Releaser ────────
rule_2_approved() {
  local in_review
  in_review=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In review")]' | sort_by_priority)
  in_review=$(filter_blocked "$in_review")

  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local card_id
    card_id=$(echo "$card_json" | jq -r '.issue_number')

    # Check issue labels first
    local has_label
    has_label=$(echo "$card_json" | jq 'any(.labels[]; . == "user-approved")')

    # Also check PR labels (user-approved is typically added to the PR, not the issue)
    if [[ "$has_label" != "true" ]]; then
      local pr_url
      pr_url=$(echo "$card_json" | jq -r '.fields["PR URL"] // ""')
      if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
        local pr_num
        pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
        if [[ -n "$pr_num" ]]; then
          has_label=$(gh pr view "$pr_num" --repo "$REPO" --json labels --jq 'any(.labels[]; .name == "user-approved")' 2>/dev/null || echo "false")
        fi
      fi
    fi

    if [[ "$has_label" == "true" ]]; then
      decide "releaser" "$card_id" "Card #$card_id In Review with user-approved label" "$(model_for releaser)"
      return 0
    fi
  done < <(echo "$in_review" | jq -c '.[]')

  return 1
}

# ── Rule 3: In Progress + draft PR with rework label → Builder ──
# Reviewer/Tester converts PR to draft and adds "rework" label when routing back.
rule_3_rework() {
  local in_progress
  in_progress=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In progress")]' | sort_by_priority)
  in_progress=$(filter_blocked "$in_progress")

  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local card_id
    card_id=$(echo "$card_json" | jq -r '.issue_number')
    local pr_url pr_num
    pr_url=$(echo "$card_json" | jq -r '.fields["PR URL"] // ""')
    [[ -z "$pr_url" || "$pr_url" == "null" ]] && continue
    pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
    [[ -z "$pr_num" ]] && continue

    local pr_info
    pr_info=$(gh pr view "$pr_num" --repo "$REPO" --json isDraft,labels --jq '{draft: .isDraft, rework: any(.labels[]; .name == "rework")}' 2>/dev/null || echo '{"draft":true,"rework":false}')
    local is_draft is_rework
    is_draft=$(echo "$pr_info" | jq -r '.draft')
    is_rework=$(echo "$pr_info" | jq -r '.rework')

    if [[ "$is_draft" == "true" && "$is_rework" == "true" ]]; then
      if is_card_stuck "$card_id"; then continue; fi
      decide "builder" "$card_id" "Card #$card_id needs rework (draft PR with rework label)" "$(model_for builder "$card_id")"
      return 0
    fi
  done < <(echo "$in_progress" | jq -c '.[]')

  return 1
}

# ── Rule 4a: In Progress + ready PR + no code-review-approved → Reviewer
# Builder marks PR ready. Reviewer does code review (no simulator).
rule_4a_reviewer() {
  local in_progress
  in_progress=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In progress")]' | sort_by_priority)
  in_progress=$(filter_blocked "$in_progress")

  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local card_id
    card_id=$(echo "$card_json" | jq -r '.issue_number')
    local pr_url pr_num
    pr_url=$(echo "$card_json" | jq -r '.fields["PR URL"] // ""')
    [[ -z "$pr_url" || "$pr_url" == "null" ]] && continue
    pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
    [[ -z "$pr_num" ]] && continue

    local pr_info
    pr_info=$(gh pr view "$pr_num" --repo "$REPO" --json isDraft,labels --jq '{draft: .isDraft, approved: any(.labels[]; .name == "tests-passed"), reviewed: any(.labels[]; .name == "code-review-approved")}' 2>/dev/null || echo '{"draft":true,"approved":false,"reviewed":false}')
    local is_draft has_ai_approved has_code_review
    is_draft=$(echo "$pr_info" | jq -r '.draft')
    has_ai_approved=$(echo "$pr_info" | jq -r '.approved')
    has_code_review=$(echo "$pr_info" | jq -r '.reviewed')

    # PR is ready, not approved, not yet code-reviewed → Reviewer
    if [[ "$is_draft" == "false" && "$has_ai_approved" == "false" && "$has_code_review" == "false" ]]; then
      if is_card_stuck "$card_id"; then continue; fi
      decide "reviewer" "$card_id" "Card #$card_id has ready PR awaiting code review" "$(model_for reviewer "$card_id")"
      return 0
    fi
  done < <(echo "$in_progress" | jq -c '.[]')

  return 1
}

# ── Rule 4b: In Progress + ready PR + code-review-approved + UI card + no visual-qa-approved → Tester
# Reviewer passed. Tester runs UITests and Visual QA (needs simulator).
rule_4b_tester() {
  local in_progress
  in_progress=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In progress")]' | sort_by_priority)
  in_progress=$(filter_blocked "$in_progress")

  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local card_id
    card_id=$(echo "$card_json" | jq -r '.issue_number')
    local pr_url pr_num
    pr_url=$(echo "$card_json" | jq -r '.fields["PR URL"] // ""')
    [[ -z "$pr_url" || "$pr_url" == "null" ]] && continue
    pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
    [[ -z "$pr_num" ]] && continue

    local pr_info
    pr_info=$(gh pr view "$pr_num" --repo "$REPO" --json isDraft,labels --jq '{draft: .isDraft, approved: any(.labels[]; .name == "tests-passed"), reviewed: any(.labels[]; .name == "code-review-approved"), vqa: any(.labels[]; .name == "visual-qa-approved")}' 2>/dev/null || echo '{"draft":true,"approved":false,"reviewed":false,"vqa":false}')
    local is_draft has_ai_approved has_code_review has_vqa
    is_draft=$(echo "$pr_info" | jq -r '.draft')
    has_ai_approved=$(echo "$pr_info" | jq -r '.approved')
    has_code_review=$(echo "$pr_info" | jq -r '.reviewed')
    has_vqa=$(echo "$pr_info" | jq -r '.vqa')

    # PR is ready, code-reviewed, not yet visual-qa-approved → Tester
    if [[ "$is_draft" == "false" && "$has_ai_approved" == "false" && "$has_code_review" == "true" && "$has_vqa" == "false" ]]; then
      if is_card_stuck "$card_id"; then continue; fi
      decide "tester" "$card_id" "Card #$card_id code review passed, awaiting Visual QA" "$(model_for tester "$card_id")"
      return 0
    fi
  done < <(echo "$in_progress" | jq -c '.[]')

  return 1
}

# ── Rule 5: In Progress + draft PR (no rework label) → Builder
# Planner creates draft PR. Builder picks it up, implements, marks ready.
rule_5_draft_pr() {
  local in_progress
  in_progress=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In progress")]' | sort_by_priority)
  in_progress=$(filter_blocked "$in_progress")

  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local card_id
    card_id=$(echo "$card_json" | jq -r '.issue_number')
    local pr_url pr_num
    pr_url=$(echo "$card_json" | jq -r '.fields["PR URL"] // ""')
    [[ -z "$pr_url" || "$pr_url" == "null" ]] && continue
    pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
    [[ -z "$pr_num" ]] && continue

    local pr_info
    pr_info=$(gh pr view "$pr_num" --repo "$REPO" --json isDraft,labels --jq '{draft: .isDraft, rework: any(.labels[]; .name == "rework")}' 2>/dev/null || echo '{"draft":true,"rework":false}')
    local is_draft is_rework
    is_draft=$(echo "$pr_info" | jq -r '.draft')
    is_rework=$(echo "$pr_info" | jq -r '.rework')

    # Draft PR without rework label → Builder needs to implement
    if [[ "$is_draft" == "true" && "$is_rework" == "false" ]]; then
      if is_card_stuck "$card_id"; then continue; fi
      decide "builder" "$card_id" "Card #$card_id has draft PR ready for implementation" "$(model_for builder "$card_id")"
      return 0
    fi
  done < <(echo "$in_progress" | jq -c '.[]')

  return 1
}

# ── Rule 6: Ready → Planner (respects WIP) ──────────────
rule_6_ready() {
  local wip
  wip=$(in_progress_count)
  if [[ "$wip" -ge "$WIP_IN_PROGRESS" ]]; then
    SKIPPED=$(echo "$SKIPPED" | jq '. + [{"card": 0, "reason": "WIP limit reached ('"$wip"'/'"$WIP_IN_PROGRESS"' In Progress)"}]')
    return 1
  fi

  local ready
  ready=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "Ready")]' | sort_by_priority)
  ready=$(filter_blocked "$ready")

  local first
  first=$(echo "$ready" | jq -r '.[0] // empty')
  [[ -z "$first" ]] && return 1

  local card_id
  card_id=$(echo "$first" | jq -r '.issue_number')
  decide "planner" "$card_id" "Card #$card_id in Ready, highest priority" "$(model_for planner)"
  return 0
}

# ── Rule 7: Backlog without HasUIChanges → Designer ──────
rule_7_needs_design() {
  local backlog
  backlog=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "Backlog")]' | sort_by_priority)
  backlog=$(filter_blocked "$backlog")

  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local has_ui
    has_ui=$(echo "$card_json" | jq -r '.fields.HasUIChanges // ""')
    if [[ -z "$has_ui" || "$has_ui" == "null" ]]; then
      local card_id
      card_id=$(echo "$card_json" | jq -r '.issue_number')
      local reason="Card #$card_id in Backlog, needs design evaluation"
      decide "designer" "$card_id" "$reason" "$(model_for designer)"
      return 0
    fi
  done < <(echo "$backlog" | jq -c '.[]')

  return 1
}

# ── Rule 8: Nothing else → idle agent (scout or maintainer) ──
rule_8_idle() {
  local idle_agent="${IDLE_MODE:-scout}"
  case "$idle_agent" in
    maintainer)
      decide "maintainer" 0 "No actionable cards, running code integrity sweep" "$(model_for maintainer)"
      ;;
    *)
      decide "scout" 0 "No actionable cards, running discovery" "$(model_for scout)"
      ;;
  esac
  return 0
}

# ── Timeout check: skip stuck agents ───────────────────
check_stuck_agents() {
  local in_progress
  in_progress=$(echo "$BOARD" | jq -c '[.cards[] | select(.fields.Status == "In progress")]')
  local count
  count=$(echo "$in_progress" | jq 'length')
  [[ "$count" -eq 0 ]] && return

  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local card_id
    card_id=$(echo "$card_json" | jq -r '.issue_number')
    local last_agent
    last_agent=$(echo "$STATE" | jq -r --arg c "$card_id" '.cards[$c].last_agent // ""')

    [[ -z "$last_agent" || "$last_agent" == "null" ]] && continue

    # Check if timer has exceeded budget
    local timer_result
    timer_result=$(bash "$SCRIPTS_DIR/state.sh" check-timer "$card_id" "$last_agent" 2>/dev/null || true)
    local timer_exit=$?

    if echo "$timer_result" | grep -q "^EXCEEDED"; then
      log_warn "Card #$card_id stuck at $last_agent for too long — skipping this card"
      SKIPPED=$(echo "$SKIPPED" | jq --argjson c "$card_id" --arg agent "$last_agent" \
        '. + [{"card": $c, "reason": ("Timeout: " + $agent + " exceeded time budget")}]')

      # Post warning comment on the issue (if not dry run)
      if [[ "$DRY_RUN" != "true" ]]; then
        gh issue comment "$card_id" --repo "$REPO" \
          --body "Warning: Agent \`$last_agent\` has exceeded its time budget on this card. Skipping re-dispatch until manually resolved." \
          2>/dev/null || true
      fi
    fi
  done < <(echo "$in_progress" | jq -c '.[]')
}

# Check if a card is stuck (exceeded timer)
is_card_stuck() {
  local card_id="$1"
  echo "$SKIPPED" | jq -e --argjson c "$card_id" 'any(.[]; .card == $c and (.reason | startswith("Timeout:")))' > /dev/null 2>&1
}

# ── Main dispatch (single) ───────────────────────────────
dispatch() {
  # Pre-check: identify stuck agents before dispatching
  check_stuck_agents

  rule_1_comment_response && return 0
  rule_2_approved && return 0
  rule_3_rework && return 0
  rule_4a_reviewer && return 0
  rule_4b_tester && return 0
  rule_5_draft_pr && return 0
  rule_6_ready && return 0
  rule_7_needs_design && return 0
  rule_8_idle && return 0
}

# ── Multi dispatch (parallel-safe) ──────────────────────
# Collects ALL eligible dispatches and filters for parallel safety.
# Returns JSON: {"decisions": [...], "skipped": [...]}
dispatch_multi() {
  check_stuck_agents

  local DECISIONS="[]"

  # Helper: add a decision if the card isn't already claimed
  add_decision() {
    local agent="$1" card="$2" reason="$3" model="$4"
    # Skip if card already in decisions
    local already
    already=$(echo "$DECISIONS" | jq --argjson c "$card" 'any(.[]; .card == $c)')
    [[ "$already" == "true" ]] && return 1
    # Skip if card is in-flight or explicitly skipped
    is_card_skipped "$card" && return 1
    DECISIONS=$(echo "$DECISIONS" | jq --arg a "$agent" --argjson c "$card" --arg r "$reason" --arg m "$model" \
      '. + [{agent: $a, card: $c, reason: $r, model: $m}]')
    return 0
  }

  # Collect from each rule (don't short-circuit — collect all)

  # Rule 0: Unaddressed PR comments
  local unaddressed
  unaddressed=$(bash "$SCRIPTS_DIR/check-pr-comments.sh" 2>/dev/null || echo "[]")
  local unaddressed_count
  unaddressed_count=$(echo "$unaddressed" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$unaddressed_count" -gt 0 ]]; then
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    while IFS= read -r comment_json; do
      local cpr ccard
      cpr=$(echo "$comment_json" | jq -r '.pr')
      ccard=$(echo "$comment_json" | jq -r '.card')
      # Stamp last_comment_check so subsequent cycles don't re-detect the same comment
      bash "$SCRIPTS_DIR/state.sh" set "$ccard" last_comment_check "$now" 2>/dev/null || true
      add_decision "builder" "$ccard" "Card #$ccard: user comment on PR #$cpr — routing to Builder" "$(model_for builder "$ccard")" || true
    done < <(echo "$unaddressed" | jq -c '.[]')
  fi

  # Rule 2: In Review + user-approved → Releaser
  local in_review
  in_review=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In review")]' | sort_by_priority)
  in_review=$(filter_blocked "$in_review")
  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local card_id
    card_id=$(echo "$card_json" | jq -r '.issue_number')
    local has_label="false"
    has_label=$(echo "$card_json" | jq 'any(.labels[]; . == "user-approved")')
    if [[ "$has_label" != "true" ]]; then
      local pr_url
      pr_url=$(echo "$card_json" | jq -r '.fields["PR URL"] // ""')
      if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
        local pr_num
        pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')
        [[ -n "$pr_num" ]] && has_label=$(gh pr view "$pr_num" --repo "$REPO" --json labels --jq 'any(.labels[]; .name == "user-approved")' 2>/dev/null || echo "false")
      fi
    fi
    [[ "$has_label" == "true" ]] && add_decision "releaser" "$card_id" "Card #$card_id In Review with user-approved label" "$(model_for releaser)" || true
  done < <(echo "$in_review" | jq -c '.[]')

  # Rules 3-5: Check In Progress cards by PR state
  local in_progress
  in_progress=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "In progress")]' | sort_by_priority)
  in_progress=$(filter_blocked "$in_progress")
  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local card_id
    card_id=$(echo "$card_json" | jq -r '.issue_number')
    local pr_url pr_num
    pr_url=$(echo "$card_json" | jq -r '.fields["PR URL"] // ""')
    pr_num=""
    if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
      pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
    fi
    # EC-6 FIX: If PR URL field missing, auto-detect PR from branch name
    if [[ -z "$pr_num" ]]; then
      pr_num=$(gh pr list --repo "$REPO" --head "feature/${card_id}-" --json number --jq '.[0].number // empty' 2>/dev/null || true)
      if [[ -n "$pr_num" ]]; then
        bash "$SCRIPTS_DIR/set-field.sh" --issue "$card_id" --field "PR URL" --value "https://github.com/$REPO/pull/$pr_num" 2>/dev/null || true
      fi
    fi
    [[ -z "$pr_num" ]] && continue
    is_card_stuck "$card_id" && continue

    local pr_info
    pr_info=$(gh pr view "$pr_num" --repo "$REPO" --json isDraft,labels --jq '{draft: .isDraft, rework: any(.labels[]; .name == "rework"), approved: any(.labels[]; .name == "tests-passed"), reviewed: any(.labels[]; .name == "code-review-approved"), vqa: any(.labels[]; .name == "visual-qa-approved")}' 2>/dev/null || echo '{"draft":true,"rework":false,"approved":false,"reviewed":false,"vqa":false}')
    local is_draft is_rework has_ai_approved
    is_draft=$(echo "$pr_info" | jq -r '.draft')
    is_rework=$(echo "$pr_info" | jq -r '.rework')
    has_ai_approved=$(echo "$pr_info" | jq -r '.approved')

    local has_code_review has_vqa
    has_code_review=$(echo "$pr_info" | jq -r '.reviewed // false')
    has_vqa=$(echo "$pr_info" | jq -r '.vqa // false')

    # Rule 3: Draft + rework label → Builder (rework)
    if [[ "$is_draft" == "true" && "$is_rework" == "true" ]]; then
      add_decision "builder" "$card_id" "Card #$card_id needs rework (draft PR with rework label)" "$(model_for builder "$card_id")" || true
    # Rule 4a: Ready PR + no code-review-approved → Reviewer
    elif [[ "$is_draft" == "false" && "$has_ai_approved" == "false" && "$has_code_review" == "false" ]]; then
      add_decision "reviewer" "$card_id" "Card #$card_id has ready PR awaiting code review" "$(model_for reviewer "$card_id")" || true
    # Rule 4b: Ready PR + code-review-approved + no visual-qa-approved → Tester
    elif [[ "$is_draft" == "false" && "$has_ai_approved" == "false" && "$has_code_review" == "true" && "$has_vqa" == "false" ]]; then
      add_decision "tester" "$card_id" "Card #$card_id code review passed, awaiting Visual QA" "$(model_for tester "$card_id")" || true
    # EC-1 FIX: Ready PR + code-review-approved + visual-qa-approved but no tests-passed → re-apply tests-passed
    elif [[ "$is_draft" == "false" && "$has_ai_approved" == "false" && "$has_code_review" == "true" && "$has_vqa" == "true" ]]; then
      add_decision "releaser" "$card_id" "Card #$card_id has all reviews but missing tests-passed — re-applying" "$(model_for releaser)" || true
    # Rule 5: Draft PR (no rework) → Builder (implementation)
    elif [[ "$is_draft" == "true" && "$is_rework" == "false" ]]; then
      add_decision "builder" "$card_id" "Card #$card_id has draft PR ready for implementation" "$(model_for builder "$card_id")" || true
    fi
  done < <(echo "$in_progress" | jq -c '.[]')

  # Rule 6: Ready → Planner (respects WIP)
  local wip
  wip=$(in_progress_count)
  if [[ "$wip" -lt "$WIP_IN_PROGRESS" ]]; then
    local ready
    ready=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "Ready")]' | sort_by_priority)
    ready=$(filter_blocked "$ready")
    # May dispatch multiple planners up to WIP limit
    local remaining_wip=$(( WIP_IN_PROGRESS - wip ))
    local dispatched=0
    while IFS= read -r card_json; do
      [[ -z "$card_json" || "$card_json" == "null" ]] && continue
      [[ "$dispatched" -ge "$remaining_wip" ]] && break
      local card_id
      card_id=$(echo "$card_json" | jq -r '.issue_number')
      if add_decision "planner" "$card_id" "Card #$card_id in Ready, highest priority" "$(model_for planner)"; then
        dispatched=$((dispatched + 1))
      fi
    done < <(echo "$ready" | jq -c '.[]')
  fi

  # Rule 7: Backlog → Designer
  local backlog
  backlog=$(echo "$BOARD" | jq '[.cards[] | select(.fields.Status == "Backlog")]' | sort_by_priority)
  backlog=$(filter_blocked "$backlog")
  while IFS= read -r card_json; do
    [[ -z "$card_json" || "$card_json" == "null" ]] && continue
    local has_ui
    has_ui=$(echo "$card_json" | jq -r '.fields.HasUIChanges // ""')
    if [[ -z "$has_ui" || "$has_ui" == "null" ]]; then
      local card_id
      card_id=$(echo "$card_json" | jq -r '.issue_number')
      add_decision "designer" "$card_id" "Card #$card_id in Backlog, needs design evaluation" "$(model_for designer)" || true
    fi
  done < <(echo "$backlog" | jq -c '.[]')

  # Rule 8: Idle agent (only if nothing else) — scout or maintainer based on idle_mode
  local decision_count
  decision_count=$(echo "$DECISIONS" | jq 'length')
  if [[ "$decision_count" -eq 0 ]]; then
    local idle_agent="${IDLE_MODE:-scout}"
    case "$idle_agent" in
      maintainer)
        add_decision "maintainer" 0 "No actionable cards, running code integrity sweep" "$(model_for maintainer)" || true
        ;;
      *)
        add_decision "scout" 0 "No actionable cards, running discovery" "$(model_for scout)" || true
        ;;
    esac
  fi

  # ── Filter for parallel safety ──────────────────────────
  # Constraint: at most one simulator agent total (in-flight + new)
  local filtered="[]"
  local new_sim_claimed=false

  while IFS= read -r d; do
    [[ -z "$d" || "$d" == "null" ]] && continue
    local dagent
    dagent=$(echo "$d" | jq -r '.agent')
    if needs_simulator "$dagent"; then
      if [[ "$SIM_IN_USE" == "true" || "$new_sim_claimed" == "true" ]]; then
        # Skip this simulator agent — sim is busy
        local dcard
        dcard=$(echo "$d" | jq -r '.card')
        SKIPPED=$(echo "$SKIPPED" | jq --argjson c "$dcard" --arg a "$dagent" \
          '. + [{card: $c, reason: ("Parallel skip: simulator in use, cannot run " + $a)}]')
        continue
      fi
      new_sim_claimed=true
    fi
    filtered=$(echo "$filtered" | jq --argjson d "$d" '. + [$d]')
  done < <(echo "$DECISIONS" | jq -c '.[]')

  # Output multi-dispatch result
  jq -n --argjson decisions "$filtered" --argjson skipped "$SKIPPED" \
    '{decisions: $decisions, skipped: $skipped}'
}

# ── Entry point ─────────────────────────────────────────
if [[ "$MULTI" == "true" ]]; then
  dispatch_multi
else
  dispatch
fi
