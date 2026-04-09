#!/bin/bash
# optimize.sh — Analyzes pipeline performance and suggests/applies optimizations.
#
# Usage:
#   ./optimize.sh analyze              # Show where time is spent
#   ./optimize.sh suggest              # Suggest optimizations
#   ./optimize.sh apply [--dry-run]    # Auto-apply safe optimizations
#
# Data sources: learnings.json, usage dir, state file, gate timing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
optimize.sh — Pipeline performance analysis and self-optimization.

Commands:
  analyze   Show time breakdown by agent and gate
  suggest   Suggest optimizations based on patterns
  apply     Auto-apply safe optimizations (--dry-run to preview)
HELP

GATE_TIMING_FILE="${GATE_TIMING_FILE:-$REPO_ROOT/.claude/delivery-loop-gate-timing.json}"
OPTIMIZATION_LOG="$REPO_ROOT/.claude/delivery-loop-optimizations.json"

ensure_timing_file() {
  if [[ ! -f "$GATE_TIMING_FILE" ]]; then
    mkdir -p "$(dirname "$GATE_TIMING_FILE")"
    echo '{"gates":{},"agents":{},"totals":{"cards_completed":0,"total_duration_sec":0}}' > "$GATE_TIMING_FILE"
  fi
}

# Record gate timing (called by quality-gate.sh after each gate)
cmd_record_gate() {
  local gate="" name="" duration="" card=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gate)     gate="$2"; shift 2 ;;
      --name)     name="$2"; shift 2 ;;
      --duration) duration="$2"; shift 2 ;;
      --card)     card="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done
  [[ -z "$gate" || -z "$duration" ]] && return 0

  ensure_timing_file
  local tmp="${GATE_TIMING_FILE}.tmp.$$"
  jq --arg g "$gate" --arg n "${name:-Gate $gate}" --argjson d "$duration" --arg c "${card:-0}" '
    .gates[$g] = (.gates[$g] // {name: $n, total_sec: 0, count: 0, avg_sec: 0, max_sec: 0, samples: []}) |
    .gates[$g].total_sec += $d |
    .gates[$g].count += 1 |
    .gates[$g].avg_sec = (.gates[$g].total_sec / .gates[$g].count) |
    .gates[$g].max_sec = ([.gates[$g].max_sec, $d] | max) |
    .gates[$g].name = $n |
    .gates[$g].samples = (.gates[$g].samples + [{card: ($c | tonumber), duration: $d}] | .[-20:])
  ' "$GATE_TIMING_FILE" > "$tmp" && mv "$tmp" "$GATE_TIMING_FILE"
}

# Record agent timing
cmd_record_agent() {
  local agent="" duration="" card=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)    agent="$2"; shift 2 ;;
      --duration) duration="$2"; shift 2 ;;
      --card)     card="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done
  [[ -z "$agent" || -z "$duration" ]] && return 0

  ensure_timing_file
  local tmp="${GATE_TIMING_FILE}.tmp.$$"
  jq --arg a "$agent" --argjson d "$duration" --arg c "${card:-0}" '
    .agents[$a] = (.agents[$a] // {total_sec: 0, count: 0, avg_sec: 0, max_sec: 0}) |
    .agents[$a].total_sec += $d |
    .agents[$a].count += 1 |
    .agents[$a].avg_sec = (.agents[$a].total_sec / .agents[$a].count) |
    .agents[$a].max_sec = ([.agents[$a].max_sec, $d] | max)
  ' "$GATE_TIMING_FILE" > "$tmp" && mv "$tmp" "$GATE_TIMING_FILE"
}

# Analyze: show where time is spent
cmd_analyze() {
  ensure_timing_file

  echo "## Pipeline Performance Analysis"
  echo ""

  # Agent time breakdown
  echo "### Agent Time (avg per card)"
  echo ""
  echo "| Agent | Avg | Max | Runs |"
  echo "|-------|-----|-----|------|"
  jq -r '.agents | to_entries | sort_by(-.value.avg_sec) | .[] |
    "| \(.key) | \(.value.avg_sec | floor)s | \(.value.max_sec | floor)s | \(.value.count) |"
  ' "$GATE_TIMING_FILE" 2>/dev/null || echo "| (no data) | — | — | — |"

  echo ""

  # Gate time breakdown (top 10 slowest)
  echo "### Slowest Gates (avg)"
  echo ""
  echo "| Gate | Name | Avg | Max | Runs |"
  echo "|------|------|-----|-----|------|"
  jq -r '.gates | to_entries | sort_by(-.value.avg_sec) | .[:10] | .[] |
    "| \(.key) | \(.value.name) | \(.value.avg_sec | floor)s | \(.value.max_sec | floor)s | \(.value.count) |"
  ' "$GATE_TIMING_FILE" 2>/dev/null || echo "| — | (no data) | — | — | — |"

  echo ""

  # Time distribution
  local total_gate_time
  total_gate_time=$(jq '[.gates[].total_sec] | add // 0' "$GATE_TIMING_FILE" 2>/dev/null || echo 0)
  local total_agent_time
  total_agent_time=$(jq '[.agents[].total_sec] | add // 0' "$GATE_TIMING_FILE" 2>/dev/null || echo 0)

  echo "### Time Distribution"
  echo "- Total gate time: ${total_gate_time}s"
  echo "- Total agent time: ${total_agent_time}s"

  # Bottleneck identification
  echo ""
  echo "### Bottlenecks"
  local slowest_gate
  slowest_gate=$(jq -r '.gates | to_entries | sort_by(-.value.avg_sec) | .[0] | "\(.value.name) (Gate \(.key)): \(.value.avg_sec | floor)s avg"' "$GATE_TIMING_FILE" 2>/dev/null || echo "none")
  local slowest_agent
  slowest_agent=$(jq -r '.agents | to_entries | sort_by(-.value.avg_sec) | .[0] | "\(.key): \(.value.avg_sec | floor)s avg"' "$GATE_TIMING_FILE" 2>/dev/null || echo "none")
  echo "- Slowest gate: $slowest_gate"
  echo "- Slowest agent: $slowest_agent"
}

# Suggest optimizations based on data
cmd_suggest() {
  ensure_timing_file

  echo "## Optimization Suggestions"
  echo ""

  local suggestions=0

  # Check if any gate consistently takes >60s
  local slow_gates
  slow_gates=$(jq -r '.gates | to_entries[] | select(.value.avg_sec > 60) | "\(.value.name) (Gate \(.key)): \(.value.avg_sec | floor)s avg"' "$GATE_TIMING_FILE" 2>/dev/null || echo "")
  if [[ -n "$slow_gates" ]]; then
    echo "### Slow Gates (>60s avg)"
    echo "$slow_gates" | while read -r line; do
      echo "- $line"
      suggestions=$((suggestions + 1))
    done
    echo "  **Suggestion:** Consider caching build artifacts between gates, parallelizing non-dependent gates"
    echo ""
  fi

  # Check if Builder is consistently slow (>15 min)
  local builder_avg
  builder_avg=$(jq -r '.agents.builder.avg_sec // 0' "$GATE_TIMING_FILE" 2>/dev/null || echo 0)
  if (( $(echo "$builder_avg > 900" | bc 2>/dev/null || echo 0) )); then
    echo "### Builder Consistently Slow (>${builder_avg}s avg)"
    echo "  **Suggestion:** Consider splitting large cards into smaller ones, or downgrading to Sonnet for simple implementations"
    echo ""
    suggestions=$((suggestions + 1))
  fi

  # Check learnings for repeated failures
  if [[ -f "$SCRIPTS_DIR/learnings.sh" ]]; then
    local rework_count
    rework_count=$(bash "$SCRIPTS_DIR/learnings.sh" stats 2>/dev/null | jq '.by_type["rework-cause"] // 0' 2>/dev/null || echo 0)
    if [[ "$rework_count" -gt 3 ]]; then
      echo "### High Rework Rate ($rework_count rework causes recorded)"
      bash "$SCRIPTS_DIR/learnings.sh" query --type rework-cause --limit 3 2>/dev/null | jq -r '.[] | "- Card #\(.card): \(.lesson)"' 2>/dev/null || true
      echo "  **Suggestion:** Add the most common rework cause to CLAUDE.md rules or Planner's spec review checklist"
      echo ""
      suggestions=$((suggestions + 1))
    fi

    local gate_failures
    gate_failures=$(bash "$SCRIPTS_DIR/learnings.sh" stats 2>/dev/null | jq '.by_type["gate-failure"] // 0' 2>/dev/null || echo 0)
    if [[ "$gate_failures" -gt 5 ]]; then
      echo "### Frequent Gate Failures ($gate_failures recorded)"
      bash "$SCRIPTS_DIR/learnings.sh" query --type gate-failure --limit 3 2>/dev/null | jq -r '.[] | "- Card #\(.card): \(.lesson)"' 2>/dev/null || true
      echo "  **Suggestion:** Add these patterns to the Builder's prompt context so it avoids them upfront"
      echo ""
      suggestions=$((suggestions + 1))
    fi
  fi

  # Check if non-UI cards are running simulator gates (wasted time)
  local sim_on_non_ui
  sim_on_non_ui=$(jq -r '
    [.gates | to_entries[] | select(.key | tonumber >= 10) | select(.value.count > 0)] | length
  ' "$GATE_TIMING_FILE" 2>/dev/null || echo 0)

  # Check model costs
  if [[ -d "$USAGE_DIR" ]]; then
    local total_cost
    total_cost=$(find "$USAGE_DIR" -name "*.json" -exec jq -r '.totals.cost_usd // 0' {} \; 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo 0)
    local card_count
    card_count=$(find "$USAGE_DIR" -name "*.json" | wc -l | tr -d ' ')
    if [[ "$card_count" -gt 0 ]]; then
      local avg_cost
      avg_cost=$(echo "scale=2; $total_cost / $card_count" | bc 2>/dev/null || echo 0)
      if (( $(echo "$avg_cost > 10" | bc 2>/dev/null || echo 0) )); then
        echo "### High Cost Per Card (\$${avg_cost} avg)"
        echo "  **Suggestion:** Consider using Sonnet for Builder on simpler cards, or reducing Planner spec verbosity"
        echo ""
        suggestions=$((suggestions + 1))
      fi
    fi
  fi

  if [[ "$suggestions" -eq 0 ]]; then
    echo "No optimizations suggested — pipeline is performing well."
  fi
}

# Apply safe optimizations automatically
cmd_apply() {
  local dry_run=false
  [[ "${1:-}" == "--dry-run" ]] && dry_run=true

  ensure_timing_file

  echo "## Auto-Applying Optimizations"
  echo ""

  local applied=0

  # Optimization 1: If gate failures are consistently from the same CLAUDE.md violation,
  # add a specific warning to the Builder prompt
  if [[ -f "$SCRIPTS_DIR/learnings.sh" ]]; then
    local recommendations
    recommendations=$(bash "$SCRIPTS_DIR/learnings.sh" recommend 2>/dev/null || echo '{"recommendations":[]}')
    local rec_count
    rec_count=$(echo "$recommendations" | jq '.recommendations | length' 2>/dev/null || echo 0)

    if [[ "$rec_count" -gt 0 ]]; then
      echo "### Learnings-Based Recommendations ($rec_count)"
      echo "$recommendations" | jq -r '.recommendations[] | "- [\(.type)] \(.suggestion)"' 2>/dev/null
      echo ""

      if [[ "$dry_run" == "false" ]]; then
        # Log applied optimizations
        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        mkdir -p "$(dirname "$OPTIMIZATION_LOG")"
        if [[ ! -f "$OPTIMIZATION_LOG" ]]; then
          echo '{"optimizations":[]}' > "$OPTIMIZATION_LOG"
        fi
        local tmp="${OPTIMIZATION_LOG}.tmp.$$"
        echo "$recommendations" | jq --arg ts "$ts" '
          .recommendations[] | {applied: $ts, type: .type, suggestion: .suggestion}
        ' 2>/dev/null | jq -s --argjson existing "$(cat "$OPTIMIZATION_LOG")" '
          $existing | .optimizations += .
        ' > "$tmp" 2>/dev/null && mv "$tmp" "$OPTIMIZATION_LOG"
        applied=$((applied + rec_count))
      else
        echo "(dry run — not applying)"
      fi
    fi
  fi

  if [[ "$applied" -eq 0 ]]; then
    echo "No auto-applicable optimizations found."
  else
    echo ""
    echo "Applied $applied optimizations. Logged to $OPTIMIZATION_LOG"
  fi
}

# ── Dispatch ──────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  record-gate)  cmd_record_gate "$@" ;;
  record-agent) cmd_record_agent "$@" ;;
  analyze)      cmd_analyze ;;
  suggest)      cmd_suggest ;;
  apply)        cmd_apply "$@" ;;
  *)
    echo "Usage: optimize.sh {analyze|suggest|apply|record-gate|record-agent} [options]" >&2
    exit 1
    ;;
esac
