#!/bin/bash
# coverage-baseline.sh — Tracks per-branch code-coverage baselines.
#
# Usage:
#   ./coverage-baseline.sh save    --branch <name> --coverage <pct>
#   ./coverage-baseline.sh get     --branch <name>
#   ./coverage-baseline.sh compare --current <pct> --branch <name>
#
# Storage: .claude/baselines/coverage.json
#
# compare returns JSON:
#   { "passed": bool, "current": <pct>, "baseline": <pct>, "delta": <num> }
#   Fails if current drops more than 1% below baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
coverage-baseline.sh — Tracks per-branch code-coverage baselines.

Usage:
  ./coverage-baseline.sh save    --branch <name> --coverage <pct>
  ./coverage-baseline.sh get     --branch <name>
  ./coverage-baseline.sh compare --current <pct> --branch <name>

Commands:
  save     Persist coverage % for a branch
  get      Retrieve baseline for a branch (falls back to autodev default)
  compare  Compare current coverage against baseline; exit 0 if within tolerance

Options:
  --branch <name>    Branch name (required)
  --coverage <pct>   Coverage percentage (required for save)
  --current <pct>    Current coverage percentage (required for compare)

Env:
  COVERAGE_DROP_TOLERANCE  Max allowed drop below baseline (default: 0 — coverage must never drop)
HELP

BASELINES_DIR="${BASELINES_DIR:-$REPO_ROOT/.claude/baselines}"
BASELINES_FILE="${BASELINES_FILE:-$BASELINES_DIR/coverage.json}"
COVERAGE_DROP_TOLERANCE="${COVERAGE_DROP_TOLERANCE:-0}"

# ── Ensure storage exists ──────────────────────────────
ensure_baselines_file() {
  if [[ ! -f "$BASELINES_FILE" ]]; then
    mkdir -p "$BASELINES_DIR"
    echo '{}' > "$BASELINES_FILE"
  fi
}

# ── Commands ───────────────────────────────────────────

cmd_save() {
  local branch="" coverage=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)   branch="$2"; shift 2 ;;
      --coverage) coverage="$2"; shift 2 ;;
      *)          log_error "save: unknown arg: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$branch" ]]; then
    log_error "save: --branch is required"
    exit 1
  fi
  if [[ -z "$coverage" ]]; then
    log_error "save: --coverage is required"
    exit 1
  fi

  ensure_baselines_file

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local updated
  updated=$(jq --arg b "$branch" --argjson c "$coverage" --arg t "$timestamp" \
    '.[$b] = $c | .updated = $t' "$BASELINES_FILE")
  echo "$updated" > "$BASELINES_FILE"

  log_info "Saved coverage baseline: $branch = $coverage%"
  echo "{\"saved\": true, \"branch\": \"$branch\", \"coverage\": $coverage}"
}

cmd_get() {
  local branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      *)        log_error "get: unknown arg: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$branch" ]]; then
    log_error "get: --branch is required"
    exit 1
  fi

  ensure_baselines_file

  local value
  value=$(jq -r --arg b "$branch" '.[$b] // empty' "$BASELINES_FILE")

  # Fall back to autodev baseline if branch-specific not found
  if [[ -z "$value" ]] && [[ "$branch" != "$BASE_BRANCH" ]]; then
    value=$(jq -r --arg b "$BASE_BRANCH" '.[$b] // empty' "$BASELINES_FILE")
    if [[ -n "$value" ]]; then
      log_info "No baseline for '$branch', using $BASE_BRANCH baseline: $value%"
    fi
  fi

  if [[ -z "$value" ]]; then
    log_info "No baseline found for '$branch' (or $BASE_BRANCH fallback)"
    echo "null"
    return 0
  fi

  echo "$value"
}

cmd_compare() {
  local current="" branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --current) current="$2"; shift 2 ;;
      --branch)  branch="$2"; shift 2 ;;
      *)         log_error "compare: unknown arg: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$current" ]]; then
    log_error "compare: --current is required"
    exit 1
  fi
  if [[ -z "$branch" ]]; then
    log_error "compare: --branch is required"
    exit 1
  fi

  local baseline
  baseline=$(cmd_get --branch "$branch" 2>/dev/null)

  # No baseline yet — pass by default
  if [[ "$baseline" == "null" || -z "$baseline" ]]; then
    log_info "No baseline exists yet — coverage check passes by default"
    jq -n --argjson c "$current" '{passed: true, current: $c, baseline: null, delta: null}'
    return 0
  fi

  local delta passed
  delta=$(echo "$current - $baseline" | bc 2>/dev/null || echo "0")
  # Check if delta < -TOLERANCE (i.e., dropped too much)
  local threshold
  threshold=$(echo "-$COVERAGE_DROP_TOLERANCE" | bc)
  if (( $(echo "$delta < $threshold" | bc 2>/dev/null || echo 0) )); then
    passed=false
    log_warn "Coverage regression: ${current}% vs baseline ${baseline}% (delta: ${delta}%, tolerance: -${COVERAGE_DROP_TOLERANCE}%)"
  else
    passed=true
    log_info "Coverage OK: ${current}% vs baseline ${baseline}% (delta: ${delta}%)"
  fi

  jq -n \
    --argjson passed "$passed" \
    --argjson current "$current" \
    --argjson baseline "$baseline" \
    --argjson delta "$delta" \
    '{passed: $passed, current: $current, baseline: $baseline, delta: $delta}'
}

# ── Dispatch ───────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  save)    cmd_save "$@" ;;
  get)     cmd_get "$@" ;;
  compare) cmd_compare "$@" ;;
  "")      log_error "Usage: coverage-baseline.sh {save|get|compare} [options]"; exit 1 ;;
  *)       log_error "Unknown command: $COMMAND"; exit 1 ;;
esac
