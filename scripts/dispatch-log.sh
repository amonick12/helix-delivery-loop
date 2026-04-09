#!/bin/bash
# dispatch-log.sh — Structured JSONL logging for the delivery loop.
# Provides append/query/failures/rotate/stats operations.
#
# Usage:
#   dispatch-log.sh append  --card <N> --agent <name> --outcome <outcome> [--error <msg>] [--duration <s>] [--preflight-checks <json>] [--cleanup-summary <json>]
#   dispatch-log.sh query   [--card <N>] [--agent <name>] [--outcome <outcome>] [--last <N>]
#   dispatch-log.sh failures [--card <N>] [--agent <name>]
#   dispatch-log.sh rotate
#   dispatch-log.sh stats   [--hours <N>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

LOG_DIR="$REPO_ROOT/.claude/plugins/helix-delivery-loop/logs"
LOG_FILE="$LOG_DIR/dispatch-log.jsonl"
ARCHIVE_FILE="$LOG_DIR/dispatch-log-archive.jsonl"

mkdir -p "$LOG_DIR"

# ── Helpers ──────────────────────────────────────────────

# macOS-compatible date for N hours ago (ISO 8601)
date_hours_ago() {
  local hours="$1"
  if date -v -${hours}H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return
  fi
  # GNU date fallback
  date -u -d "${hours} hours ago" +%Y-%m-%dT%H:%M:%SZ
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ── Subcommands ──────────────────────────────────────────

cmd_append() {
  local card="" agent="" outcome="" error_msg="" duration="" preflight_checks="" cleanup_summary=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --card)             card="$2"; shift 2 ;;
      --agent)            agent="$2"; shift 2 ;;
      --outcome)          outcome="$2"; shift 2 ;;
      --error)            error_msg="$2"; shift 2 ;;
      --duration)         duration="$2"; shift 2 ;;
      --preflight-checks) preflight_checks="$2"; shift 2 ;;
      --cleanup-summary)  cleanup_summary="$2"; shift 2 ;;
      *) log_error "Unknown append flag: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$card" || -z "$agent" || -z "$outcome" ]]; then
    log_error "append requires --card, --agent, and --outcome"
    exit 1
  fi

  local timestamp
  timestamp="$(now_iso)"

  local entry
  entry=$(jq -n -c \
    --arg ts "$timestamp" \
    --arg card "$card" \
    --arg agent "$agent" \
    --arg outcome "$outcome" \
    --arg error "$error_msg" \
    --arg duration "$duration" \
    --arg preflight "$preflight_checks" \
    --arg cleanup "$cleanup_summary" \
    '{
      timestamp: $ts,
      card: ($card | tonumber),
      agent: $agent,
      outcome: $outcome
    }
    + (if $error != "" then {error: $error} else {} end)
    + (if $duration != "" then {duration_s: ($duration | tonumber)} else {} end)
    + (if $preflight != "" then {preflight_checks: ($preflight | fromjson)} else {} end)
    + (if $cleanup != "" then {cleanup_summary: ($cleanup | fromjson)} else {} end)
    ')

  echo "$entry" >> "$LOG_FILE"
  log_info "Logged: card=$card agent=$agent outcome=$outcome"
}

cmd_query() {
  local card="" agent="" outcome="" last=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --card)    card="$2"; shift 2 ;;
      --agent)   agent="$2"; shift 2 ;;
      --outcome) outcome="$2"; shift 2 ;;
      --last)    last="$2"; shift 2 ;;
      *) log_error "Unknown query flag: $1"; exit 1 ;;
    esac
  done

  if [[ ! -f "$LOG_FILE" ]]; then
    echo "[]"
    return
  fi

  local filter="."
  [[ -n "$card" ]]    && filter="$filter | select(.card == ($card | tonumber))"
  [[ -n "$agent" ]]   && filter="$filter | select(.agent == \"$agent\")"
  [[ -n "$outcome" ]] && filter="$filter | select(.outcome == \"$outcome\")"

  local result
  if [[ -n "$last" ]]; then
    result=$(jq -s "[ .[] | $filter ] | .[-${last}:]" "$LOG_FILE")
  else
    result=$(jq -s "[ .[] | $filter ]" "$LOG_FILE")
  fi

  echo "$result"
}

cmd_failures() {
  local card="" agent=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --card)  card="$2"; shift 2 ;;
      --agent) agent="$2"; shift 2 ;;
      *) log_error "Unknown failures flag: $1"; exit 1 ;;
    esac
  done

  if [[ ! -f "$LOG_FILE" ]]; then
    echo "0"
    return
  fi

  local filter='select(.outcome == "preflight_fail" or .outcome == "agent_error")'
  [[ -n "$card" ]]  && filter="$filter | select(.card == ($card | tonumber))"
  [[ -n "$agent" ]] && filter="$filter | select(.agent == \"$agent\")"

  jq -s "[ .[] | $filter ] | length" "$LOG_FILE"
}

cmd_rotate() {
  if [[ ! -f "$LOG_FILE" ]]; then
    log_info "No log file to rotate"
    return
  fi

  local total
  total=$(wc -l < "$LOG_FILE" | tr -d ' ')

  if [[ "$total" -le 500 ]]; then
    log_info "Log has $total entries (≤500), no rotation needed"
    return
  fi

  local archive_count=$(( total - 500 ))
  head -n "$archive_count" "$LOG_FILE" >> "$ARCHIVE_FILE"
  local tmp
  tmp=$(mktemp)
  tail -n 500 "$LOG_FILE" > "$tmp"
  mv "$tmp" "$LOG_FILE"
  log_info "Rotated $archive_count entries to archive, kept 500"
}

cmd_stats() {
  local hours=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hours) hours="$2"; shift 2 ;;
      *) log_error "Unknown stats flag: $1"; exit 1 ;;
    esac
  done

  if [[ ! -f "$LOG_FILE" ]]; then
    jq -n '{total:0, success:0, preflight_fail:0, agent_error:0, dead_lettered:0, avg_duration_s:0}'
    return
  fi

  local cutoff=""
  if [[ -n "$hours" ]]; then
    cutoff="$(date_hours_ago "$hours")"
  fi

  jq -s --arg cutoff "$cutoff" '
    [ .[] | if $cutoff != "" then select(.timestamp >= $cutoff) else . end ] as $entries |
    {
      total:          ($entries | length),
      success:        ([ $entries[] | select(.outcome == "success") ]        | length),
      preflight_fail: ([ $entries[] | select(.outcome == "preflight_fail") ] | length),
      agent_error:    ([ $entries[] | select(.outcome == "agent_error") ]    | length),
      dead_lettered:  ([ $entries[] | select(.outcome == "dead_lettered") ]  | length),
      avg_duration_s: (
        [ $entries[] | select(.duration_s != null) | .duration_s ] |
        if length > 0 then (add / length * 100 | round / 100) else 0 end
      )
    }
  ' "$LOG_FILE"
}

# ── Main ────────────────────────────────────────────────

show_help_if_requested "$@" <<'HELP'
dispatch-log.sh — Structured JSONL logging for the delivery loop.

Subcommands:
  append   --card <N> --agent <name> --outcome <outcome> [--error <msg>] [--duration <s>] [--preflight-checks <json>] [--cleanup-summary <json>]
  query    [--card <N>] [--agent <name>] [--outcome <outcome>] [--last <N>]
  failures [--card <N>] [--agent <name>]
  rotate
  stats    [--hours <N>]
HELP

subcommand="${1:-}"
shift || true

case "$subcommand" in
  append)   cmd_append "$@" ;;
  query)    cmd_query "$@" ;;
  failures) cmd_failures "$@" ;;
  rotate)   cmd_rotate "$@" ;;
  stats)    cmd_stats "$@" ;;
  *)
    log_error "Unknown subcommand: $subcommand"
    log_error "Usage: dispatch-log.sh {append|query|failures|rotate|stats} [flags]"
    exit 1
    ;;
esac
