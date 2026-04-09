#!/bin/bash
# state.sh — Persistent per-card state for cross-conversation continuity.
#
# Usage:
#   ./state.sh get <card-id>                      # Get full card state as JSON
#   ./state.sh get <card-id> <field>               # Get one field value
#   ./state.sh set <card-id> <field> <value>       # Set one field
#   ./state.sh set-json <card-id> <field> <json>   # Set one field with JSON value
#   ./state.sh clear <card-id>                     # Remove card state
#   ./state.sh list                                # List all tracked cards
#   ./state.sh start-timer <card-id> <agent>       # Start agent timer
#   ./state.sh check-timer <card-id> <agent>       # Check if agent has exceeded time budget
#
# State file: .claude/delivery-loop-state.json
# Fields per card: last_agent, last_error, screenshot_paths, retry_count,
#                  last_updated, timer_start, timer_agent, timer_budget_min

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
state.sh — Persistent per-card state for cross-conversation continuity.

Usage:
  ./state.sh get <card-id>                      # Get full card state as JSON
  ./state.sh get <card-id> <field>               # Get one field value
  ./state.sh set <card-id> <field> <value>       # Set one field
  ./state.sh set-json <card-id> <field> <json>   # Set one field with JSON value
  ./state.sh clear <card-id>                     # Remove card state
  ./state.sh list                                # List all tracked cards
  ./state.sh start-timer <card-id> <agent>       # Start agent timer
  ./state.sh check-timer <card-id> <agent>       # Check time budget (exit 1 if exceeded)

Time budgets (minutes): Builder=30, Reviewer=15, Tester=20, Designer=20, Scout=25, Releaser=10, Planner=30

State file: .claude/delivery-loop-state.json
HELP

# Ensure state file exists
if [[ ! -f "$STATE_FILE" ]]; then
  echo '{"cards":{}}' > "$STATE_FILE"
fi

# ── File locking (mkdir-based for macOS compatibility) ──
STATE_LOCK="${STATE_FILE}.lock"

acquire_state_lock() {
  local timeout=5
  local start=$(date +%s)
  while ! mkdir "$STATE_LOCK" 2>/dev/null; do
    local now=$(date +%s)
    if (( now - start >= timeout )); then
      # Check for stale lock (older than 30s)
      if [[ -f "$STATE_LOCK/pid" ]]; then
        local lock_pid
        lock_pid=$(cat "$STATE_LOCK/pid" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
          log_warn "Removing stale state lock from dead PID $lock_pid"
          rm -rf "$STATE_LOCK"
          continue
        fi
      fi
      log_warn "Could not acquire state lock after ${timeout}s"
      return 1
    fi
    sleep 0.1
  done
  echo $$ > "$STATE_LOCK/pid"
}

release_state_lock() {
  rm -rf "$STATE_LOCK"
}

# Ensure lock is released on exit
trap 'release_state_lock 2>/dev/null || true' EXIT

# Time budgets per agent (minutes) — portable for macOS bash 3.2
get_agent_budget() {
  case "$1" in
    builder)   echo 30 ;;
    planner)   echo 30 ;;
    reviewer)  echo 10 ;;
    tester)    echo 20 ;;
    designer)  echo 20 ;;
    scout)     echo 25 ;;
    releaser)  echo 10 ;;
    *)         echo 20 ;;
  esac
}

cmd_get() {
  local card_id="$1"
  local field="${2:-}"

  if [[ -z "$field" ]]; then
    jq --arg id "$card_id" '.cards[$id] // {}' "$STATE_FILE"
  else
    jq -r --arg id "$card_id" --arg f "$field" '.cards[$id][$f] // empty' "$STATE_FILE"
  fi
}

cmd_set() {
  local card_id="$1"
  local field="$2"
  local value="$3"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  acquire_state_lock || return 1
  local tmp="${STATE_FILE}.tmp"
  jq --arg id "$card_id" --arg f "$field" --arg v "$value" --arg now "$now" '
    .cards[$id] //= {} |
    .cards[$id][$f] = $v |
    .cards[$id].last_updated = $now
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  release_state_lock

  echo "Set cards.$card_id.$field=$value"
}

cmd_set_json() {
  local card_id="$1"
  local field="$2"
  local json_value="$3"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  acquire_state_lock || return 1
  local tmp="${STATE_FILE}.tmp"
  jq --arg id "$card_id" --arg f "$field" --argjson v "$json_value" --arg now "$now" '
    .cards[$id] //= {} |
    .cards[$id][$f] = $v |
    .cards[$id].last_updated = $now
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  release_state_lock

  echo "Set cards.$card_id.$field (JSON)"
}

cmd_clear() {
  local card_id="$1"
  acquire_state_lock || return 1
  local tmp="${STATE_FILE}.tmp"
  jq --arg id "$card_id" 'del(.cards[$id])' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  release_state_lock
  echo "Cleared state for card $card_id"
}

cmd_list() {
  jq -r '.cards | to_entries[] | "\(.key): agent=\(.value.last_agent // "none"), updated=\(.value.last_updated // "never"), retries=\(.value.retry_count // 0)"' "$STATE_FILE"
}

cmd_start_timer() {
  local card_id="$1"
  local agent="$2"
  local now
  now=$(date +%s)
  local budget
  budget=$(get_agent_budget "$agent")

  acquire_state_lock || return 1
  local tmp="${STATE_FILE}.tmp"
  jq --arg id "$card_id" --arg agent "$agent" --argjson start "$now" --argjson budget "$budget" --arg now_iso "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
    .cards[$id] //= {} |
    .cards[$id].timer_start = $start |
    .cards[$id].timer_agent = $agent |
    .cards[$id].timer_budget_min = $budget |
    .cards[$id].last_agent = $agent |
    .cards[$id].last_updated = $now_iso
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  release_state_lock

  echo "Started ${budget}m timer for $agent on card $card_id"
}

cmd_check_timer() {
  local card_id="$1"
  local agent="$2"
  local now
  now=$(date +%s)

  local timer_start
  timer_start=$(jq -r --arg id "$card_id" '.cards[$id].timer_start // 0' "$STATE_FILE")
  local budget_min
  budget_min=$(jq -r --arg id "$card_id" '.cards[$id].timer_budget_min // 30' "$STATE_FILE")

  if [[ "$timer_start" == "0" ]]; then
    echo "No timer running for card $card_id"
    return 0
  fi

  local elapsed_sec=$(( now - timer_start ))
  local budget_sec=$(( budget_min * 60 ))
  local elapsed_min=$(( elapsed_sec / 60 ))

  if [[ $elapsed_sec -gt $budget_sec ]]; then
    echo "EXCEEDED: $agent on card $card_id has been running ${elapsed_min}m (budget: ${budget_min}m)"
    return 1
  else
    local remaining_min=$(( (budget_sec - elapsed_sec) / 60 ))
    echo "OK: $agent on card $card_id — ${elapsed_min}m elapsed, ${remaining_min}m remaining (budget: ${budget_min}m)"
    return 0
  fi
}

# ── Validated Handoff ───────────────────────────────────
cmd_handoff() {
  local card_id="$1"
  local from_agent="$2"

  case "$from_agent" in
    builder)
      # Builder handoff requires a PR to exist for this card
      local pr_url
      pr_url=$(gh pr list --repo "$REPO" --search "$card_id in:title" --json url --jq '.[0].url // ""' 2>/dev/null || echo "")
      if [[ -z "$pr_url" || "$pr_url" == "null" ]]; then
        log_error "Handoff rejected: builder finished card #$card_id but no PR found"
        cmd_set "$card_id" "handoff_error" "No PR exists for card #$card_id"
        return 1
      fi
      ;;
    planner)
      # Planner handoff requires a worktree to exist
      local wt_path=""
      for wt in /tmp/helix-wt/feature/${card_id}-*; do
        [[ -d "$wt" ]] && wt_path="$wt" && break
      done
      if [[ -z "$wt_path" ]]; then
        log_error "Handoff rejected: planner finished card #$card_id but no worktree found"
        cmd_set "$card_id" "handoff_error" "No worktree for card #$card_id"
        return 1
      fi
      ;;
    reviewer)
      # Reviewer handoff — no special validation needed (code review only)
      ;;
    tester)
      # Tester handoff — no special validation needed (Visual QA results in PR)
      ;;
  esac

  # Preconditions passed — write handoff
  cmd_set "$card_id" "handoff_ready" "true"
  cmd_set "$card_id" "handoff_from" "$from_agent"
  cmd_set "$card_id" "handoff_error" ""
  log_info "Handoff from $from_agent accepted for card #$card_id"
}

# ── Checkpoint / Rollback ──────────────────────────────
cmd_checkpoint() {
  local card_id="$1"
  local phase="$2"

  acquire_state_lock || return 1
  local card_state
  card_state=$(jq --arg id "$card_id" '.cards[$id] // {}' "$STATE_FILE")
  local tmp="${STATE_FILE}.tmp"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg id "$card_id" --arg phase "$phase" --argjson snap "$card_state" --arg now "$now" '
    .cards[$id].checkpoints //= {} |
    .cards[$id].checkpoints[$phase] = ($snap + {checkpoint_at: $now}) |
    .cards[$id].last_updated = $now
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  release_state_lock
  log_info "Checkpoint saved for card #$card_id at phase $phase"
}

cmd_rollback() {
  local card_id="$1"
  local to_phase="$2"

  acquire_state_lock || return 1
  local checkpoint
  checkpoint=$(jq --arg id "$card_id" --arg phase "$to_phase" \
    '.cards[$id].checkpoints[$phase] // empty' "$STATE_FILE")

  if [[ -z "$checkpoint" || "$checkpoint" == "null" ]]; then
    release_state_lock
    log_error "No checkpoint found for card #$card_id at phase $to_phase"
    return 1
  fi

  local tmp="${STATE_FILE}.tmp"
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local existing_checkpoints
  existing_checkpoints=$(jq --arg id "$card_id" '.cards[$id].checkpoints // {}' "$STATE_FILE")

  jq --arg id "$card_id" --argjson snap "$checkpoint" --argjson cps "$existing_checkpoints" --arg now "$now" --arg phase "$to_phase" '
    .cards[$id] = ($snap + {
      checkpoints: $cps,
      last_updated: $now,
      rolled_back_to: $phase,
      rework_target: $phase
    })
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  release_state_lock
  log_info "Rolled back card #$card_id to $to_phase checkpoint"
}

cmd_increment_retry() {
  local card_id="$1"
  local agent="$2"
  local key="retry_count_${agent}"
  local current
  current=$(cmd_get "$card_id" "$key" 2>/dev/null || echo "0")
  [[ -z "$current" || "$current" == "null" ]] && current=0
  local new_count=$((current + 1))
  cmd_set "$card_id" "$key" "$new_count"
  echo "$new_count"
}

# ── In-Flight Registry ────────────────────────────────
# Tracks which agents are currently running to support parallel dispatch.

cmd_register_inflight() {
  local card_id="$1"
  local agent="$2"
  local now
  now=$(date +%s)
  local sim=false
  needs_simulator "$agent" && sim=true

  acquire_state_lock || return 1
  local tmp="${STATE_FILE}.tmp"
  jq --arg card "$card_id" --arg agent "$agent" --argjson started "$now" --argjson sim "$sim" '
    .in_flight //= [] |
    # Remove any existing entry for this card (defensive)
    .in_flight = [.in_flight[] | select(.card != $card)] |
    .in_flight += [{card: $card, agent: $agent, started_at: $started, needs_simulator: $sim}]
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  release_state_lock

  log_info "Registered in-flight: $agent on card #$card_id (simulator=$sim)"
}

cmd_deregister_inflight() {
  local card_id="$1"
  local agent="$2"

  acquire_state_lock || return 1
  local tmp="${STATE_FILE}.tmp"
  jq --arg card "$card_id" --arg agent "$agent" '
    .in_flight //= [] |
    .in_flight = [.in_flight[] | select(.card != $card or .agent != $agent)]
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  release_state_lock

  log_info "Deregistered in-flight: $agent on card #$card_id"
}

cmd_list_inflight() {
  # Clean up stale entries (older than agent time budget) before returning
  local now
  now=$(date +%s)
  local raw
  raw=$(jq '.in_flight // []' "$STATE_FILE")
  local stale_count
  stale_count=$(echo "$raw" | jq --argjson now "$now" '[.[] | select(
    ($now - .started_at) > (
      if .agent == "builder" then 1800
      elif .agent == "planner" then 1800
      elif .agent == "reviewer" then 600
      elif .agent == "tester" then 1200
      elif .agent == "designer" then 1200
      elif .agent == "scout" then 1500
      elif .agent == "releaser" then 600
      else 1200 end
    )
  )] | length')

  if [[ "$stale_count" -gt 0 ]]; then
    acquire_state_lock || { echo "$raw"; return; }
    local tmp="${STATE_FILE}.tmp"
    jq --argjson now "$now" '
      .in_flight //= [] |
      .in_flight = [.in_flight[] | select(
        ($now - .started_at) <= (
          if .agent == "builder" then 1800
          elif .agent == "planner" then 1800
          elif .agent == "reviewer" then 600
      elif .agent == "tester" then 1200
          elif .agent == "designer" then 1200
          elif .agent == "scout" then 1500
          elif .agent == "releaser" then 600
          else 1200 end
        )
      )]
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    release_state_lock
    jq '.in_flight // []' "$STATE_FILE"
  else
    echo "$raw"
  fi
}

cmd_check_retries() {
  local card_id="$1"
  local agent="$2"
  local max="${3:-2}"
  local key="retry_count_${agent}"
  local current
  current=$(cmd_get "$card_id" "$key" 2>/dev/null || echo "0")
  [[ -z "$current" || "$current" == "null" ]] && current=0

  if [[ "$current" -ge "$max" ]]; then
    echo "EXCEEDED: $agent retries ($current >= $max) on card #$card_id"
    return 1
  else
    echo "OK: $agent retries ($current/$max) on card #$card_id"
    return 0
  fi
}

case "${1:-}" in
  get)
    [[ -z "${2:-}" ]] && echo "Usage: state.sh get <card-id> [field]" && exit 1
    cmd_get "$2" "${3:-}"
    ;;
  set)
    [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]] && echo "Usage: state.sh set <card-id> <field> <value>" && exit 1
    cmd_set "$2" "$3" "$4"
    ;;
  set-json)
    [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]] && echo "Usage: state.sh set-json <card-id> <field> <json>" && exit 1
    cmd_set_json "$2" "$3" "$4"
    ;;
  clear)
    [[ -z "${2:-}" ]] && echo "Usage: state.sh clear <card-id>" && exit 1
    cmd_clear "$2"
    ;;
  list)
    cmd_list
    ;;
  start-timer)
    [[ -z "${2:-}" || -z "${3:-}" ]] && echo "Usage: state.sh start-timer <card-id> <agent>" && exit 1
    cmd_start_timer "$2" "$3"
    ;;
  check-timer)
    [[ -z "${2:-}" || -z "${3:-}" ]] && echo "Usage: state.sh check-timer <card-id> <agent>" && exit 1
    cmd_check_timer "$2" "$3"
    ;;
  handoff)
    [[ -z "${2:-}" || -z "${3:-}" ]] && echo "Usage: state.sh handoff <card-id> <from-agent>" && exit 1
    cmd_handoff "$2" "$3"
    ;;
  checkpoint)
    [[ -z "${2:-}" || -z "${3:-}" ]] && echo "Usage: state.sh checkpoint <card-id> <phase>" && exit 1
    cmd_checkpoint "$2" "$3"
    ;;
  rollback)
    [[ -z "${2:-}" || -z "${3:-}" ]] && echo "Usage: state.sh rollback <card-id> <to-phase>" && exit 1
    cmd_rollback "$2" "$3"
    ;;
  increment-retry)
    [[ -z "${2:-}" || -z "${3:-}" ]] && echo "Usage: state.sh increment-retry <card-id> <agent>" && exit 1
    cmd_increment_retry "$2" "$3"
    ;;
  check-retries)
    [[ -z "${2:-}" || -z "${3:-}" ]] && echo "Usage: state.sh check-retries <card-id> <agent> [max]" && exit 1
    cmd_check_retries "$2" "$3" "${4:-2}"
    ;;
  register-inflight)
    [[ -z "${2:-}" || -z "${3:-}" ]] && echo "Usage: state.sh register-inflight <card-id> <agent>" && exit 1
    cmd_register_inflight "$2" "$3"
    ;;
  deregister-inflight)
    [[ -z "${2:-}" || -z "${3:-}" ]] && echo "Usage: state.sh deregister-inflight <card-id> <agent>" && exit 1
    cmd_deregister_inflight "$2" "$3"
    ;;
  list-inflight)
    cmd_list_inflight
    ;;
  *)
    echo "Usage: state.sh {get|set|set-json|clear|list|start-timer|check-timer|handoff|checkpoint|rollback|increment-retry|check-retries|register-inflight|deregister-inflight|list-inflight} [args...]"
    exit 1
    ;;
esac
