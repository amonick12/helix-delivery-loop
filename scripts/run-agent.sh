#!/bin/bash
# run-agent.sh — Entry point for every agent invocation. Enforces the lifecycle.
#
# Two-phase execution:
#   Phase 1 (prepare): validate, load context, select model, start tracking,
#     move card, pickup, construct prompt → output prompt to stdout
#   Phase 2 (finish): end tracking, write handoff, post cost, chain
#
# Usage:
#   ./run-agent.sh prepare <agent> --card <N> [--model <override>] [--rework]
#   ./run-agent.sh finish <agent> --card <N> [--input-tokens N --output-tokens N --model M] [--failed --reason "msg"] [--chain]
#
# Requires: jq, gh (for non-DRY_RUN)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
run-agent.sh — Entry point for every agent invocation.

Phase 1 (prepare):
  ./run-agent.sh prepare <agent> --card <N> [--model <override>] [--rework]
  Validates card, loads context, selects model, outputs prompt to stdout.

Phase 2 (finish):
  ./run-agent.sh finish <agent> --card <N> \
    [--input-tokens N --output-tokens N --model M] \
    [--failed --reason "msg"] [--chain]
  Records usage, writes handoff (or rework on failure), posts cost, chains.

Agents: scout, designer, planner, builder, reviewer, tester, releaser
HELP

# ── Valid agents ────────────────────────────────────────
VALID_AGENTS="scout maintainer designer planner builder reviewer tester releaser"

is_valid_agent() {
  local agent="$1"
  for a in $VALID_AGENTS; do
    [[ "$a" == "$agent" ]] && return 0
  done
  return 1
}

# ── Column validation per agent ─────────────────────────
# Maps agent → expected column(s) the card should be in
expected_column_for() {
  local agent="$1"
  case "$agent" in
    scout)      echo "__any__" ;;  # scout can run without a specific card
    maintainer) echo "__any__" ;;  # maintainer can run without a specific card
    designer) echo "Backlog" ;;
    planner)  echo "Ready|In progress" ;;
    builder)  echo "In progress|In review" ;;  # "In review" allowed for user comment rework (rule #1)
    reviewer) echo "In progress" ;;
    tester)   echo "In progress" ;;
    releaser) echo "In review" ;;
    *)        echo "__any__" ;;
  esac
}

# ── Parse phase ─────────────────────────────────────────
PHASE="${1:-}"
if [[ -z "$PHASE" ]]; then
  echo "Error: phase required (prepare|finish)" >&2
  echo "Usage: run-agent.sh {prepare|finish} <agent> --card <N> [options]" >&2
  exit 1
fi
shift

AGENT="${1:-}"
if [[ -z "$AGENT" ]]; then
  echo "Error: agent name required" >&2
  echo "Usage: run-agent.sh $PHASE <agent> --card <N> [options]" >&2
  exit 1
fi
shift

if ! is_valid_agent "$AGENT"; then
  echo "Error: unknown agent '$AGENT'. Valid: $VALID_AGENTS" >&2
  exit 1
fi

# ── Parse flags ─────────────────────────────────────────
CARD=""
MODEL_OVERRIDE=""
REWORK=false
CHAIN=false
FAILED=false
FAILURE_REASON=""
MINIMAL=false
INPUT_TOKENS=""
OUTPUT_TOKENS=""
FINISH_MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)           CARD="$2"; shift 2 ;;
    --model)          MODEL_OVERRIDE="$2"; shift 2 ;;
    --rework)         REWORK=true; shift ;;
    --chain)          CHAIN=true; shift ;;
    --failed)         FAILED=true; shift ;;
    --reason)         FAILURE_REASON="$2"; shift 2 ;;
    --minimal)        MINIMAL=true; shift ;;
    --input-tokens)   INPUT_TOKENS="$2"; shift 2 ;;
    --output-tokens)  OUTPUT_TOKENS="$2"; shift 2 ;;
    *)                echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$CARD" ]]; then
  echo "Error: --card <N> is required" >&2
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Model selection ─────────────────────────────────────
select_model() {
  # --model flag overrides everything
  if [[ -n "$MODEL_OVERRIDE" ]]; then
    echo "$MODEL_OVERRIDE"
    return
  fi

  # Rework downgrades builder to sonnet
  if [[ "$REWORK" == "true" && "$AGENT" == "builder" ]]; then
    echo "$MODEL_BUILDER_REWORK"
    return
  fi

  # Default from config
  local var_name="MODEL_$(echo "$AGENT" | tr '[:lower:]' '[:upper:]')"
  echo "${!var_name}"
}

# ══════════════════════════════════════════════════════════
# PHASE 1: PREPARE
# ══════════════════════════════════════════════════════════
phase_prepare() {
  local model
  model=$(select_model)

  # ── Step 1: Validate card ───────────────────────────────
  local board_json
  if [[ -n "${BOARD_OVERRIDE:-}" && -f "${BOARD_OVERRIDE:-}" ]]; then
    board_json=$(cat "$BOARD_OVERRIDE")
  elif [[ "$DRY_RUN" == "1" ]]; then
    board_json='{"cards":[]}'
  else
    board_json=$(bash "$SCRIPTS_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null) || {
      log_error "Failed to read board for card #$CARD"
      exit 1
    }
  fi

  local card_json
  card_json=$(echo "$board_json" | jq --argjson id "$CARD" '[.cards[] | select(.issue_number == $id)] | .[0] // empty')

  if [[ -z "$card_json" || "$card_json" == "null" ]]; then
    # Agents with __any__ column (scout, maintainer) can run with card 0 (no specific card)
    local expected_cols
    expected_cols=$(expected_column_for "$AGENT")
    if [[ "$CARD" == "0" && "$expected_cols" == "__any__" ]]; then
      card_json=$(jq -n '{issue_number: 0, title: "No card (sweep)", fields: {Status: "__any__"}, labels: [], recent_comments: []}')
    elif [[ "$DRY_RUN" == "1" ]]; then
      # In DRY_RUN mode with no board data, create a stub card
      card_json=$(jq -n --argjson id "$CARD" '{issue_number: $id, title: "Test Card", fields: {Status: "Ready"}, labels: [], recent_comments: []}')
    else
      log_error "Card #$CARD not found on board"
      exit 1
    fi
  fi

  # Check for BlockedReason
  local blocked
  blocked=$(echo "$card_json" | jq -r '.fields.BlockedReason // ""')
  if [[ -n "$blocked" && "$blocked" != "null" ]]; then
    log_error "Card #$CARD is blocked: $blocked"
    exit 1
  fi

  # Validate column for this agent
  local card_status
  card_status=$(echo "$card_json" | jq -r '.fields.Status // ""')
  local expected_cols
  expected_cols=$(expected_column_for "$AGENT")
  if [[ "$expected_cols" != "__any__" ]]; then
    local col_match=false
    local status_lower
    status_lower=$(echo "$card_status" | tr '[:upper:]' '[:lower:]')
    IFS='|' read -ra cols_arr <<< "$expected_cols"
    for col in "${cols_arr[@]}"; do
      if [[ "$status_lower" == "$(echo "$col" | tr '[:upper:]' '[:lower:]')" ]]; then
        col_match=true
        break
      fi
    done
    if [[ "$col_match" == "false" && "$DRY_RUN" != "1" ]]; then
      log_error "Card #$CARD is in '$card_status' but $AGENT expects: $expected_cols"
      exit 1
    fi
  fi

  # ── Step 1b: Artifact directory ─────────────────────────
  local artifact_dir
  artifact_dir=$(ensure_artifact_dir "$CARD")

  # ── Step 2: Load context ────────────────────────────────
  local card_title
  card_title=$(echo "$card_json" | jq -r '.title // "Untitled"')
  local card_url
  card_url=$(echo "$card_json" | jq -r '.url // ""')
  local card_labels
  card_labels=$(echo "$card_json" | jq -r '[.labels[] // empty] | join(", ")')

  # Load state info
  local card_state='{}'
  if [[ -f "$STATE_FILE" ]]; then
    card_state=$(jq --arg c "$CARD" '.cards[$c] // {}' "$STATE_FILE" 2>/dev/null || echo '{}')
  fi

  # Load issue body (skip in DRY_RUN)
  local issue_body=""
  if [[ "$DRY_RUN" != "1" && -n "$card_url" ]]; then
    issue_body=$(gh issue view "$CARD" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
  fi

  # Load recent comments from board JSON
  local recent_comments=""
  recent_comments=$(echo "$card_json" | jq -r '
    [.recent_comments[] | "**\(.author)** (\(.created)):\n\(.body)"] | join("\n\n---\n\n")
  ' 2>/dev/null || echo "")

  # Extract Planner's spec and implementation plan — prefer artifact files over comment parsing
  local planner_spec="" planner_plan=""
  if [[ "$AGENT" == "builder" || "$AGENT" == "reviewer" || "$AGENT" == "tester" ]]; then
    if [[ -f "$artifact_dir/$ARTIFACT_SPEC" ]]; then
      planner_spec=$(cat "$artifact_dir/$ARTIFACT_SPEC")
    else
      planner_spec=$(echo "$card_json" | jq -r '
        [.recent_comments[] | select(.body | test("(?i)(technical spec|data model changes|component hierarchy)")) | .body] | first // ""
      ' 2>/dev/null || echo "")
      # Persist to artifact file for next agent
      if [[ -n "$planner_spec" ]]; then
        echo "$planner_spec" > "$artifact_dir/$ARTIFACT_SPEC"
      fi
    fi
    if [[ -f "$artifact_dir/$ARTIFACT_PLAN" ]]; then
      planner_plan=$(cat "$artifact_dir/$ARTIFACT_PLAN")
    else
      planner_plan=$(echo "$card_json" | jq -r '
        [.recent_comments[] | select(.body | test("(?i)implementation plan")) | .body] | first // ""
      ' 2>/dev/null || echo "")
      if [[ -n "$planner_plan" ]]; then
        echo "$planner_plan" > "$artifact_dir/$ARTIFACT_PLAN"
      fi
    fi
  fi

  # Load design URL for mockup reference
  local design_url=""
  design_url=$(echo "$card_json" | jq -r '.fields.DesignURL // ""')

  # Resolve worktree path
  local worktree_path=""
  if [[ -f "$SCRIPTS_DIR/worktree.sh" ]]; then
    worktree_path=$(bash "$SCRIPTS_DIR/worktree.sh" path --card "$CARD" 2>/dev/null || echo "")
  fi

  # ── Step 3: Model already selected above ────────────────

  # ── Step 4: Start tracking ──────────────────────────────
  if [[ "$DRY_RUN" != "1" ]]; then
    bash "$SCRIPTS_DIR/track-usage.sh" start --card "$CARD" --agent "$AGENT" 2>/dev/null || true
  fi

  # ── Step 5: Move card to In Progress ────────────────────
  if [[ "$DRY_RUN" != "1" ]]; then
    case "$AGENT" in
      planner|builder|reviewer|tester)
        local current_status
        current_status=$(echo "$card_json" | jq -r '.fields.Status // ""')
        if [[ "$(echo "$current_status" | tr '[:upper:]' '[:lower:]')" != "in progress" ]]; then
          bash "$SCRIPTS_DIR/move-card.sh" --issue "$CARD" --to "In progress" 2>/dev/null || true
        fi
        ;;
    esac
  fi

  # ── Step 5b: Strip approval labels when Builder picks up rework ─
  # tests-passed and user-approved must be removed so Reviewer re-runs gates
  # and Releaser doesn't merge a card that's being reworked.
  if [[ "$DRY_RUN" != "1" && "$AGENT" == "builder" ]]; then
    local pr_url pr_num
    pr_url=$(echo "$card_json" | jq -r '.fields["PR URL"] // ""')
    pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)
    if [[ -n "$pr_num" ]]; then
      for label in tests-passed user-approved; do
        local has_label
        has_label=$(gh pr view "$pr_num" --repo "$REPO" --json labels \
          --jq "[.labels[].name] | any(. == \"$label\")" 2>/dev/null || echo "false")
        if [[ "$has_label" == "true" ]]; then
          gh pr edit "$pr_num" --repo "$REPO" --remove-label "$label" 2>/dev/null || true
          log_info "Removed '$label' from PR #$pr_num (Builder rework)"
        fi
      done
    fi
  fi

  # ── Step 6: Pickup + checkpoint + register in-flight ─────
  if [[ -f "$SCRIPTS_DIR/state.sh" ]]; then
    bash "$SCRIPTS_DIR/state.sh" set "$CARD" last_agent "$AGENT" 2>/dev/null || true
    bash "$SCRIPTS_DIR/state.sh" checkpoint "$CARD" "$AGENT" 2>/dev/null || true
    bash "$SCRIPTS_DIR/state.sh" register-inflight "$CARD" "$AGENT" 2>/dev/null || true
  fi

  # ── Step 7: Construct prompt ────────────────────────────
  local agent_ref="$REFS_DIR/agent-${AGENT}.md"
  local agent_checklist=""
  if [[ -f "$agent_ref" ]]; then
    agent_checklist=$(cat "$agent_ref")
  else
    log_warn "No reference file found at $agent_ref"
  fi

  # Build the structured prompt
  local agent_label
  agent_label="$(echo "$AGENT" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"
  local prompt=""
  prompt+="# Agent: ${agent_label} — Card #${CARD}
"
  prompt+="
## Card Details
- **Title:** ${card_title}
- **Issue:** #${CARD}
- **URL:** ${card_url}
- **Labels:** ${card_labels:-none}
- **Model:** ${model}
"

  if [[ "$REWORK" == "true" ]]; then
    local rework_reason
    rework_reason=$(echo "$card_json" | jq -r '.fields.ReworkReason // ""')
    prompt+="- **Mode:** REWORK
- **Rework Reason:** ${rework_reason}
"
  fi

  if [[ -n "$issue_body" ]]; then
    prompt+="
## Issue Body
${issue_body}
"
  fi

  # Add worktree path if available
  if [[ -n "$worktree_path" ]]; then
    prompt+="
## Worktree
- **Path:** ${worktree_path}
- **Branch:** feature/${CARD}-*
"
  fi

  # In minimal mode, skip verbose context — agents can fetch what they need via scripts
  if [[ "$MINIMAL" == "true" ]]; then
    prompt+="
## Context (minimal mode)
- Spec: \`cat ${artifact_dir}/${ARTIFACT_SPEC}\`
- Plan: \`cat ${artifact_dir}/${ARTIFACT_PLAN}\`
- Design: ${design_url:-none}
- Comments: \`gh issue view ${CARD} --repo ${REPO} --json comments\`
- Use these commands to fetch context as needed rather than reading it all upfront.
"
  else
    # Add Planner's spec (for Builder and Reviewer)
    if [[ -n "$planner_spec" ]]; then
      prompt+="
## Technical Spec (from Planner)
${planner_spec}
"
    fi

    # Add Planner's implementation plan (for Builder)
    if [[ -n "$planner_plan" ]]; then
      prompt+="
## Implementation Plan (from Planner)
${planner_plan}
"
    fi

    # Add design mockup reference
    if [[ -n "$design_url" && "$design_url" != "null" ]]; then
      prompt+="
## UI Mockups
- **Design URL:** ${design_url}
- Use the Read tool to view the mockup image at this URL
- Match your implementation to the mockup's layout, colors, and component structure
"
    fi

    # Add recent comments from the issue
    if [[ -n "$recent_comments" ]]; then
      prompt+="
## Recent Comments
${recent_comments}
"
    fi
  fi

  # Add artifact directory reference
  prompt+="
## Artifacts
- **Directory:** ${artifact_dir}
- Write spec to: ${artifact_dir}/${ARTIFACT_SPEC}
- Write plan to: ${artifact_dir}/${ARTIFACT_PLAN}
- Test results: ${artifact_dir}/${ARTIFACT_TEST_RESULTS}
- Verification: ${artifact_dir}/${ARTIFACT_VERIFICATION}
"

  # Add state context
  local loop_count
  loop_count=$(echo "$card_state" | jq -r '.loop_count // 0')
  local last_agent
  last_agent=$(echo "$card_state" | jq -r '.last_agent // "none"')
  prompt+="
## State
- **Loop Count:** ${loop_count}
- **Previous Agent:** ${last_agent}
"

  # Add simulator/build rules (injected into EVERY agent prompt)
  prompt+="
## Simulator Rules
- Do NOT boot, launch, install, or screenshot the simulator
- Do NOT use build.sh (fails in worktrees) — use xcodebuild directly
- Do NOT move the user's mouse or steal window focus
- All builds and tests run on macOS destination unless explicitly told otherwise
"

  # Add Karpathy guidelines (applies to every agent)
  prompt+="
## Karpathy Guidelines

1. **Think Before Coding** — State assumptions explicitly. If multiple interpretations exist, present them. Push back when a simpler approach exists.
2. **Simplicity First** — Minimum code that solves the problem. No speculative features, abstractions for single-use code, or error handling for impossible scenarios.
3. **Surgical Changes** — Touch only what you must. Don't improve adjacent code, comments, or formatting. Match existing style. Every changed line should trace to the task.
4. **Goal-Driven Execution** — Define verifiable success criteria. Transform tasks into testable goals. State a brief plan with verification checks.
"

  # Add agent reference / checklist
  if [[ -n "$agent_checklist" ]]; then
    prompt+="
## Agent Instructions
${agent_checklist}
"
  fi

  # ── Step 7b: Inject lessons learned ─────────────────────
  local learnings_output=""
  if [[ -f "$SCRIPTS_DIR/learnings.sh" ]]; then
    learnings_output=$(bash "$SCRIPTS_DIR/learnings.sh" query --agent "$AGENT" --limit 5 2>/dev/null || echo "[]")
    if [[ -n "$learnings_output" && "$learnings_output" != "[]" ]]; then
      local formatted_learnings
      formatted_learnings=$(echo "$learnings_output" | jq -r '
        .[] | "- **[\(.type)]** (card #\(.card)): \(.lesson)" +
        (if .resolution then "\n  Resolution: \(.resolution)" else "" end)
      ' 2>/dev/null || echo "")
      if [[ -n "$formatted_learnings" ]]; then
        prompt+="
## Lessons Learned (from previous cards)
${formatted_learnings}
"
      fi
    fi
  fi

  # ── Step 8: Output prompt ───────────────────────────────
  # Output model selection as a comment for the caller
  echo "MODEL=${model}" >&2
  echo "$prompt"
}

# ══════════════════════════════════════════════════════════
# PHASE 2: FINISH
# ══════════════════════════════════════════════════════════
phase_finish() {
  local model="${FINISH_MODEL:-$(select_model)}"

  # ── Step 9b: Unaddressed-comment gate ────────────────────
  # Block finish if there are user comments on the PR after the last bot
  # reply. Only applies to agents that work on PRs (Builder, Reviewer,
  # Tester) and only on a successful run — failed runs are routed back
  # to rework regardless.
  if [[ "$DRY_RUN" != "1" && "$FAILED" != "true" \
        && ("$AGENT" == "builder" || "$AGENT" == "reviewer" || "$AGENT" == "tester") ]]; then
    local pr_url_unaddressed pr_num_unaddressed
    pr_url_unaddressed=$("$SCRIPTS_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null | jq -r '.cards[0].fields["PR URL"] // ""' || echo "")
    pr_num_unaddressed=$(echo "$pr_url_unaddressed" | grep -oE '[0-9]+$' || true)
    if [[ -n "$pr_num_unaddressed" && -x "$SCRIPTS_DIR/check-unaddressed-comments.sh" ]]; then
      if ! bash "$SCRIPTS_DIR/check-unaddressed-comments.sh" --pr "$pr_num_unaddressed" 2>&1; then
        log_error "Finish blocked by unaddressed-comment gate. $AGENT must address user comments on PR #$pr_num_unaddressed before finish."
        bash "$SCRIPTS_DIR/state.sh" set "$CARD" rework_target "$AGENT" 2>/dev/null || true
        FAILED=true
      fi
    fi
  fi

  # ── Step 10: End tracking ───────────────────────────────
  if [[ "$DRY_RUN" != "1" && -n "$INPUT_TOKENS" && -n "$OUTPUT_TOKENS" ]]; then
    bash "$SCRIPTS_DIR/track-usage.sh" end \
      --card "$CARD" --agent "$AGENT" \
      --input-tokens "$INPUT_TOKENS" --output-tokens "$OUTPUT_TOKENS" \
      --model "$model" 2>/dev/null || true
  fi

  # ── Step 11: Write handoff (validated) ───────────────────
  if [[ -f "$SCRIPTS_DIR/state.sh" ]]; then
    if [[ "$FAILED" == "true" ]]; then
      # Increment retry counter and check for rollback
      local retry_count
      retry_count=$(bash "$SCRIPTS_DIR/state.sh" increment-retry "$CARD" "$AGENT" 2>/dev/null || echo "1")

      if [[ ("$AGENT" == "reviewer" || "$AGENT" == "tester") ]] && ! bash "$SCRIPTS_DIR/state.sh" check-retries "$CARD" "$AGENT" 2 2>/dev/null; then
        log_warn "$AGENT failed 2x on card #$CARD — rolling back to builder"
        bash "$SCRIPTS_DIR/state.sh" rollback "$CARD" "builder" 2>/dev/null || {
          bash "$SCRIPTS_DIR/state.sh" set "$CARD" rework_target "builder" 2>/dev/null || true
        }
        bash "$SCRIPTS_DIR/state.sh" set "$CARD" "retry_count_$AGENT" "0" 2>/dev/null || true
      else
        bash "$SCRIPTS_DIR/state.sh" set "$CARD" rework_target "$AGENT" 2>/dev/null || true
      fi
      bash "$SCRIPTS_DIR/state.sh" set "$CARD" last_agent "$AGENT" 2>/dev/null || true
      log_info "Card #$CARD: failure handled for $AGENT (retry $retry_count)"
    else
      # Use validated handoff — checks preconditions before writing
      if ! bash "$SCRIPTS_DIR/state.sh" handoff "$CARD" "$AGENT" 2>/dev/null; then
        log_warn "Handoff validation failed for $AGENT on card #$CARD — marking as rework"
        bash "$SCRIPTS_DIR/state.sh" set "$CARD" rework_target "$AGENT" 2>/dev/null || true
      else
        # Clear any stale rework_target from a previous failed run
        bash "$SCRIPTS_DIR/state.sh" set "$CARD" rework_target "" 2>/dev/null || true
      fi
      bash "$SCRIPTS_DIR/state.sh" set "$CARD" last_agent "$AGENT" 2>/dev/null || true
      log_info "Card #$CARD: handoff from $AGENT"
    fi
  fi

  # ── Step 11b: Move card to In Review after successful Tester pass (or Reviewer for non-UI) ─
  # apply-tests-passed.sh already handles this move, but as a safety net:
  if [[ "$DRY_RUN" != "1" && "$FAILED" != "true" && ("$AGENT" == "tester" || "$AGENT" == "reviewer") ]]; then
    # Only move if tests-passed was applied (check PR labels)
    local pr_url_check pr_num_check
    pr_url_check=$("$SCRIPTS_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null | jq -r '.cards[0].fields["PR URL"] // ""' || echo "")
    pr_num_check=$(echo "$pr_url_check" | grep -oE '[0-9]+$' || true)
    if [[ -n "$pr_num_check" ]]; then
      local has_ai
      has_ai=$(gh pr view "$pr_num_check" --repo "$REPO" --json labels --jq 'any(.labels[]; .name == "tests-passed")' 2>/dev/null || echo "false")
      if [[ "$has_ai" == "true" ]]; then
        bash "$SCRIPTS_DIR/move-card.sh" --issue "$CARD" --to "In review" 2>/dev/null || true
      fi
    fi
  fi

  # ── Step 11c: Update comment timestamp ──────────────────
  if [[ "$DRY_RUN" != "1" && -f "$SCRIPTS_DIR/update-comment-ts.sh" ]]; then
    bash "$SCRIPTS_DIR/update-comment-ts.sh" --card "$CARD" 2>/dev/null || true
  fi

  # ── Step 12: Post cost ──────────────────────────────────
  if [[ "$DRY_RUN" != "1" && -n "$INPUT_TOKENS" && -n "$OUTPUT_TOKENS" ]]; then
    # Post usage summary to the card
    bash "$SCRIPTS_DIR/track-usage.sh" post --card "$CARD" 2>/dev/null || true
  fi

  # ── Step 13: Chain ──────────────────────────────────────
  if [[ "$CHAIN" == "true" && "$FAILED" != "true" ]]; then
    log_info "Chaining: dispatching next agent"
    if [[ -f "$SCRIPTS_DIR/dispatcher.sh" ]]; then
      bash "$SCRIPTS_DIR/dispatcher.sh" 2>/dev/null || true
    fi
  fi

  # ── Step 14: Deregister in-flight ────────────────────────
  if [[ -f "$SCRIPTS_DIR/state.sh" ]]; then
    bash "$SCRIPTS_DIR/state.sh" deregister-inflight "$CARD" "$AGENT" 2>/dev/null || true
  fi

  log_info "Phase finish complete for $AGENT on card #$CARD"
}

# ── Dispatch phase ──────────────────────────────────────
case "$PHASE" in
  prepare) phase_prepare ;;
  finish)  phase_finish ;;
  *)
    echo "Error: unknown phase '$PHASE'. Use 'prepare' or 'finish'." >&2
    exit 1
    ;;
esac
