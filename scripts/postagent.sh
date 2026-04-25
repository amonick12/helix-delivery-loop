#!/bin/bash
# postagent.sh — Post-agent reconciliation: cleanup, logging, failure comments, dead-lettering.
# Runs after every agent invocation regardless of exit code.
#
# Usage:
#   postagent.sh --agent <agent> --card <N> [--exit-code <N>] [--error "msg"] [--duration <secs>]
#
# Cleanup steps (always run):
#   1. Orphaned worktrees (cleanup on releaser success, preserve on failure)
#   2. Stale labels (remove tests-passed if reviewer/tester failed)
#   3. Stuck handoff fields (clear handoff_ready if agent failed mid-handoff)
#   4. Lingering simulator (shutdown + release lock if tester/scout/releaser)
#   5. Log outcome via dispatch-log.sh
#   6. Post failure comment on card (if exit != 0)
#   7. Dead-letter check (>= 3 failures)
#   8. Rotate log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ── Parse arguments ─────────────────────────────────────
AGENT=""
CARD=""
EXIT_CODE=0
ERROR_MSG=""
DURATION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)     AGENT="$2"; shift 2 ;;
    --card)      CARD="$2"; shift 2 ;;
    --exit-code) EXIT_CODE="$2"; shift 2 ;;
    --error)     ERROR_MSG="$2"; shift 2 ;;
    --duration)  DURATION="$2"; shift 2 ;;
    *) log_error "Unknown flag: $1"; exit 1 ;;
  esac
done

if [[ -z "$AGENT" || -z "$CARD" ]]; then
  log_error "postagent.sh requires --agent and --card"
  exit 1
fi

# Track what cleanup steps were performed
CLEANUP_WORKTREE="skipped"
CLEANUP_LABELS="skipped"
CLEANUP_HANDOFF="skipped"
CLEANUP_SIMULATOR="skipped"

# ── 1. Cleanup: orphaned worktrees ──────────────────────
cleanup_worktrees() {
  if [[ "$AGENT" == "releaser" && "$EXIT_CODE" -eq 0 ]]; then
    # Only clean up if the PR was actually MERGED (not just a TestFlight deploy)
    local pr_url
    pr_url=$("$SCRIPT_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null \
      | jq -r '.cards[0].fields["PR URL"] // empty' 2>/dev/null || echo "")
    local pr_num
    pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
    local pr_state="OPEN"
    if [[ -n "$pr_num" ]]; then
      pr_state=$(gh pr view "$pr_num" --repo "$REPO" --json state --jq '.state' 2>/dev/null || echo "OPEN")
    fi

    if [[ "$pr_state" == "MERGED" ]]; then
      log_info "Releaser merged PR — cleaning up worktree for card $CARD"
      if "$SCRIPT_DIR/worktree.sh" cleanup --card "$CARD" 2>/dev/null; then
        CLEANUP_WORKTREE="cleaned"
      else
        CLEANUP_WORKTREE="cleanup_failed"
        log_warn "Worktree cleanup failed for card $CARD"
      fi

      # If this PR was the LAST sub-card of an epic, clean the epic's mockups.
      # The cleanup script preserves any mockup file whose View struct is still
      # referenced from shipping code (Builder reused it), so this is safe.
      local epic_id
      epic_id=$(gh issue view "$CARD" --repo "$REPO" --json body \
        --jq '.body' 2>/dev/null \
        | grep -oiE '(\*\*Epic:?\*\*|Epic:|Parent epic:|Part of epic|Epic #)\s*#?[0-9]+' \
        | grep -oE '[0-9]+' \
        | head -1 || true)
      if [[ -n "$epic_id" ]]; then
        local epic_status
        epic_status=$("$SCRIPT_DIR/check-epic-completion.sh" --epic "$epic_id" --repo "$REPO" 2>/dev/null || echo '{"all_merged":false}')
        local all_merged
        all_merged=$(echo "$epic_status" | jq -r '.all_merged // false')
        if [[ "$all_merged" == "true" ]]; then
          log_info "Last sub-card of epic #$epic_id merged — running mockup cleanup"
          "$SCRIPT_DIR/cleanup-epic-mockups.sh" --epic "$epic_id" 2>&1 \
            | grep -v "^$" >&2 \
            || log_warn "Mockup cleanup for epic #$epic_id failed (non-blocking)"
        fi
      fi
    else
      log_info "Releaser succeeded (TestFlight deploy) — preserving worktree (PR still open)"
      CLEANUP_WORKTREE="preserved_testflight"
    fi
  elif [[ "$EXIT_CODE" -ne 0 ]]; then
    log_info "Agent failed — preserving worktree for retry"
    CLEANUP_WORKTREE="preserved_for_retry"
  fi
}

# ── 2. Cleanup: stale labels ───────────────────────────
cleanup_stale_labels() {
  if [[ ("$AGENT" == "reviewer" || "$AGENT" == "tester") && "$EXIT_CODE" -ne 0 ]]; then
    log_info "$AGENT failed — checking for stale tests-passed label"
    # Get PR URL from board
    PR_URL=$("$SCRIPT_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null \
      | jq -r '.cards[0].fields["PR URL"] // empty' 2>/dev/null || echo "")
    if [[ -n "$PR_URL" ]]; then
      PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || echo "")
      if [[ -n "$PR_NUMBER" ]]; then
        # Check if tests-passed label exists and remove it
        if gh pr view "$PR_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null | grep -q "tests-passed"; then
          gh pr edit "$PR_NUMBER" --repo "$REPO" --remove-label "tests-passed" 2>/dev/null
          CLEANUP_LABELS="removed_ai_approved"
          log_info "Removed tests-passed label from PR #$PR_NUMBER"
        else
          CLEANUP_LABELS="no_label_found"
        fi
      fi
    else
      CLEANUP_LABELS="no_pr_found"
    fi
  fi
}

# ── 3. Cleanup: stuck handoff fields ───────────────────
cleanup_stuck_handoff() {
  if [[ "$EXIT_CODE" -ne 0 ]]; then
    HANDOFF_READY=$("$SCRIPT_DIR/state.sh" get "$CARD" handoff_ready 2>/dev/null || echo "")
    HANDOFF_FROM=$("$SCRIPT_DIR/state.sh" get "$CARD" handoff_from 2>/dev/null || echo "")
    if [[ "$HANDOFF_READY" == "true" && "$HANDOFF_FROM" == "$AGENT" ]]; then
      "$SCRIPT_DIR/state.sh" set "$CARD" handoff_ready "false" 2>/dev/null
      CLEANUP_HANDOFF="cleared"
      log_info "Cleared stuck handoff_ready for card $CARD (was from $AGENT)"
    else
      CLEANUP_HANDOFF="not_stuck"
    fi
  fi
}

# ── 4. Cleanup: lingering simulator ────────────────────
cleanup_simulator() {
  if needs_simulator "$AGENT"; then
    log_info "$AGENT finished — shutting down simulators and releasing lock"
    xcrun simctl shutdown all 2>/dev/null || true
    release_simulator_lock 2>/dev/null || true
    CLEANUP_SIMULATOR="shutdown_and_unlocked"
  fi
}

# ── 5. Log outcome ─────────────────────────────────────
log_outcome() {
  OUTCOME="success"
  if [[ "$EXIT_CODE" -ne 0 ]]; then
    OUTCOME="agent_error"
  fi

  CLEANUP_JSON=$(jq -n -c \
    --arg wt "$CLEANUP_WORKTREE" \
    --arg lb "$CLEANUP_LABELS" \
    --arg ho "$CLEANUP_HANDOFF" \
    --arg si "$CLEANUP_SIMULATOR" \
    '{worktree: $wt, labels: $lb, handoff: $ho, simulator: $si}')

  APPEND_ARGS=(
    append
    --card "$CARD"
    --agent "$AGENT"
    --outcome "$OUTCOME"
    --cleanup-summary "$CLEANUP_JSON"
  )
  if [[ -n "$ERROR_MSG" ]]; then
    APPEND_ARGS+=(--error "$ERROR_MSG")
  fi
  if [[ -n "$DURATION" ]]; then
    APPEND_ARGS+=(--duration "$DURATION")
  fi

  "$SCRIPT_DIR/dispatch-log.sh" "${APPEND_ARGS[@]}"
}

# ── 6. Post failure comment on card ────────────────────
post_failure_comment() {
  if [[ "$EXIT_CODE" -ne 0 && "$CARD" != "0" ]]; then
    FAIL_COUNT=$("$SCRIPT_DIR/dispatch-log.sh" failures --card "$CARD" --agent "$AGENT" 2>/dev/null || echo "0")
    WILL_RETRY="yes"
    if [[ "$FAIL_COUNT" -ge 3 ]]; then
      WILL_RETRY="no (dead-lettered)"
    fi

    COMMENT_BODY="### Agent Failure Report

| Field | Value |
|-------|-------|
| **Agent** | \`$AGENT\` |
| **Attempt** | $FAIL_COUNT |
| **Error** | ${ERROR_MSG:-N/A} |
| **Cleanup** | worktree=$CLEANUP_WORKTREE, labels=$CLEANUP_LABELS, handoff=$CLEANUP_HANDOFF, simulator=$CLEANUP_SIMULATOR |
| **Will Retry** | $WILL_RETRY |"

    gh issue comment "$CARD" --repo "$REPO" --body "$COMMENT_BODY" 2>/dev/null || \
      log_warn "Failed to post failure comment on card $CARD"
  fi
}

# ── 7. Dead letter check ──────────────────────────────
dead_letter_check() {
  if [[ "$EXIT_CODE" -ne 0 ]]; then
    FAIL_COUNT=$("$SCRIPT_DIR/dispatch-log.sh" failures --card "$CARD" --agent "$AGENT" 2>/dev/null || echo "0")
    if [[ "$FAIL_COUNT" -ge 3 ]]; then
      log_warn "Card $CARD has $FAIL_COUNT failures for $AGENT — dead-lettering"
      gh issue edit "$CARD" --repo "$REPO" --add-label "dead-letter" 2>/dev/null || \
        log_warn "Failed to add dead-letter label to card $CARD"

      # Log the dead-letter outcome
      "$SCRIPT_DIR/dispatch-log.sh" append \
        --card "$CARD" \
        --agent "$AGENT" \
        --outcome "dead_lettered" \
        --error "Exceeded max retries ($FAIL_COUNT failures)" 2>/dev/null || true

      # Queue a notification email so the loop doesn't go silent on the user.
      # Drained by /delivery-loop's pre-dispatch step alongside design/epic emails.
      queue_dead_letter_email "$CARD" "$AGENT" "$FAIL_COUNT"
    fi
  fi
}

queue_dead_letter_email() {
  local card="$1" agent="$2" fail_count="$3"
  local to="${EPIC_NOTIFY_TO:-amonick12@gmail.com}"
  local queue_dir="${EPIC_EMAIL_QUEUE_DIR:-/tmp/helix-epic-emails-pending}"
  mkdir -p "$queue_dir"
  local queue_file="$queue_dir/dead-letter-${card}.json"

  # If we've already notified for this card, don't re-queue (the file persists
  # until the orchestrator drains it; rerunning postagent on the same card
  # shouldn't spam).
  if [[ -f "$queue_file" ]]; then
    log_info "Dead-letter email already queued at $queue_file — skipping"
    return 0
  fi

  local title issue_url last_error
  title=$(gh issue view "$card" --repo "$REPO" --json title -q '.title' 2>/dev/null || echo "Card #$card")
  issue_url="https://github.com/${REPO}/issues/${card}"
  last_error=$("$SCRIPT_DIR/dispatch-log.sh" failures --card "$card" --agent "$agent" --details 2>/dev/null \
    | jq -r '.[-1].error // "(no error captured)"' 2>/dev/null || echo "(no error captured)")

  local body_file="/tmp/dead-letter-email-${card}.md"
  cat > "$body_file" <<EOF
**Loop is stuck on card #${card} — ${title}**

The ${agent} agent failed ${fail_count} times in a row on this card. The dispatcher will skip it from now on (filtered by the \`dead-letter\` label) until the underlying issue is fixed.

**Card:** ${issue_url}
**Failing agent:** ${agent}
**Last error:**

\`\`\`
${last_error}
\`\`\`

**To resume the loop on this card:**
1. Read the failures: \`bash scripts/dispatch-log.sh failures --card ${card}\`
2. Fix the root cause (usually wrong acceptance criteria, a code conflict, or an environment issue).
3. Remove the dead-letter label: \`gh issue edit ${card} --repo ${REPO} --remove-label dead-letter\`
4. Reset the retry counter: \`bash scripts/state.sh set ${card} retry_count_${agent} 0\`

The card will be picked up on the next dispatch.

---

This is a third email category alongside the design-approval and testflight-approval emails. It only fires when an agent gives up; everything else stays autonomous.
EOF

  jq -n \
    --arg to "$to" \
    --arg subject "[Helix] Loop stuck on card #${card} — ${agent} dead-lettered after ${fail_count} failures" \
    --arg body "$(cat "$body_file")" \
    --arg card "$card" \
    --arg agent "$agent" \
    --arg fail_count "$fail_count" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{to:$to, subject:$subject, body:$body, card:($card|tonumber), agent:$agent, fail_count:($fail_count|tonumber), kind:"dead-letter", created_at:$created_at, sent:false}' \
    > "$queue_file"
  rm -f "$body_file"
  log_info "Queued dead-letter email at $queue_file — orchestrator drains via Gmail MCP"
}

# ── 8. Prune zombie processes ─────────────────────────
prune_zombies() {
  # Kill orphaned xcodebuild processes from worktrees (not the main repo)
  local killed=0
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    kill "$pid" 2>/dev/null && killed=$((killed + 1))
  done < <(pgrep -f "xcodebuild.*helix-wt" 2>/dev/null || true)

  # Kill orphaned simctl processes older than 30 minutes
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    local elapsed
    elapsed=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)
    if [[ "$elapsed" -gt 1800 ]]; then
      kill "$pid" 2>/dev/null && killed=$((killed + 1))
    fi
  done < <(pgrep -f "simctl" 2>/dev/null || true)

  [[ "$killed" -gt 0 ]] && log_info "Pruned $killed zombie processes"
}

# ── 9. Rotate log ─────────────────────────────────────
rotate_log() {
  "$SCRIPT_DIR/dispatch-log.sh" rotate 2>/dev/null || true
}

# ── 10. Deregister in-flight ──────────────────────────
deregister_agent() {
  "$SCRIPT_DIR/state.sh" deregister-inflight "$CARD" "$AGENT" 2>/dev/null || true
}

# ── 11. Self-heal stuck states ────────────────────────
self_heal() {
  [[ "$CARD" == "0" ]] && return
  local pr_url
  pr_url=$("$SCRIPT_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null \
    | jq -r ".cards[0].fields[\"PR URL\"] // empty" 2>/dev/null || echo "")
  [[ -z "$pr_url" || "$pr_url" == "null" ]] && return
  local pr_num
  pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
  [[ -z "$pr_num" ]] && return

  local labels
  labels=$(gh pr view "$pr_num" --repo "$REPO" --json labels --jq '[.labels[].name]' 2>/dev/null || echo "[]")
  local has_cr has_vqa has_ai
  has_cr=$(echo "$labels" | jq 'any(. == "code-review-approved")')
  has_vqa=$(echo "$labels" | jq 'any(. == "visual-qa-approved")')
  has_ai=$(echo "$labels" | jq 'any(. == "tests-passed")')

  # EC-1: Has both reviews but no tests-passed → re-apply
  if [[ "$has_cr" == "true" && "$has_vqa" == "true" && "$has_ai" == "false" ]]; then
    log_warn "Self-heal EC-1: Card #$CARD missing tests-passed — applying"
    "$SCRIPT_DIR/apply-tests-passed.sh" --pr "$pr_num" --card "$CARD" 2>/dev/null || true
  fi

  # EC-7: Planner ran on an epic but produced no sub-cards → escalate.
  # An epic's job for Planner is to break it into sub-cards (linked issues).
  # If Planner exits with no linked sub-cards, the loop will stall: nothing
  # to dispatch Builder against. Detect and route back to Planner with a
  # clear failure reason so dead-letter triggers after retries.
  if [[ "$AGENT" == "planner" && "$EXIT_CODE" -eq 0 ]]; then
    local is_epic
    is_epic=$(gh issue view "$CARD" --repo "$REPO" --json labels \
      --jq '[.labels[].name] | any(. == "epic")' 2>/dev/null || echo "false")
    if [[ "$is_epic" == "true" ]]; then
      local sub_count
      sub_count=$(gh issue list --repo "$REPO" --state all --search "linked:issue-${CARD}" \
        --json number --jq 'length' 2>/dev/null || echo 0)
      if [[ "${sub_count:-0}" -lt 1 ]]; then
        log_warn "Self-heal EC-7: Planner ran on epic #$CARD but produced 0 sub-cards"
        gh issue comment "$CARD" --repo "$REPO" --body "bot: Planner finished but no sub-cards were created. The epic PRD must be broken into individual cards before Builder can run. Re-routing Planner." 2>/dev/null || true
        # Treat as a Planner failure for retry-counting purposes
        EXIT_CODE=1
        ERROR_MSG="Planner produced 0 sub-cards on epic #$CARD"
      fi
    fi
  fi

  # EC-9: Has tests-passed but card still In Progress → move to In Review
  if [[ "$has_ai" == "true" ]]; then
    local card_status
    card_status=$("$SCRIPT_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null \
      | jq -r '.cards[0].fields.Status // ""' 2>/dev/null || echo "")
    if [[ "$(echo "$card_status" | tr '[:upper:]' '[:lower:]')" == "in progress" ]]; then
      log_warn "Self-heal EC-9: Card #$CARD has tests-passed but In Progress — moving to In Review"
      "$SCRIPT_DIR/move-card.sh" --issue "$CARD" --to "In review" 2>/dev/null || true
    fi
  fi

  # EC-10: Epic last-sub-card TestFlight gate.
  # If THIS card is a sub-card of an epic AND it has both code-review-approved
  # and visual-qa-approved (regardless of user-approved), check whether it's the
  # LAST remaining sub-card. If so, fire notify-epic-testflight.sh which builds
  # TestFlight, gathers screenshots, emails the user, and labels the PR
  # `epic-testflight-pending` so the Releaser will hold the merge.
  if [[ "$has_cr" == "true" && "$has_vqa" == "true" ]]; then
    # Find the parent epic (issue with `epic` label that this card's body references).
    local body
    body=$(gh issue view "$CARD" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
    local parent_epic
    parent_epic=$(echo "$body" | grep -oE 'epic #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
    if [[ -n "$parent_epic" ]]; then
      log_info "Card #$CARD is a sub-card of epic #$parent_epic — checking completion gate"
      "$SCRIPT_DIR/notify-epic-testflight.sh" --epic "$parent_epic" 2>&1 | tail -3 || true
    fi
  fi
}

# ── Execute all steps ──────────────────────────────────
log_info "postagent.sh: agent=$AGENT card=$CARD exit=$EXIT_CODE"

cleanup_worktrees
cleanup_stale_labels
cleanup_stuck_handoff
cleanup_simulator
prune_zombies

# ── Validate PR labels (fix contradictions) ───────────
validate_labels() {
  if [[ "$CARD" != "0" ]]; then
    local pr_url
    pr_url=$("$SCRIPT_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null \
      | jq -r '.cards[0].fields["PR URL"] // empty' 2>/dev/null || echo "")
    if [[ -n "$pr_url" ]]; then
      local pr_num
      pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
      [[ -n "$pr_num" ]] && "$SCRIPT_DIR/validate-pr-labels.sh" --pr "$pr_num" 2>/dev/null || true
    fi
  fi
}

validate_labels
self_heal
log_outcome
post_failure_comment
dead_letter_check
deregister_agent
rotate_log

log_info "postagent.sh: complete"
exit 0
