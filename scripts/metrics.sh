#!/bin/bash
# metrics.sh — Delivery health stats from board + state + usage data.
#
# Usage:
#   ./metrics.sh                    # Human-readable output, last 30 days
#   ./metrics.sh --json             # JSON output
#   ./metrics.sh --period 7d        # Filter to last 7 days
#   ./metrics.sh --period 90d       # Filter to last 90 days
#
# Data sources:
#   Board:  read-board.sh or BOARD_OVERRIDE env var
#   State:  STATE_FILE env var (delivery-loop-state.json)
#   Usage:  USAGE_DIR env var (per-card usage JSON files)
#
# Requires: jq, bc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
metrics.sh — Delivery health stats from board + state + usage data.

Usage:
  ./metrics.sh                    # Human-readable output, last 30 days
  ./metrics.sh --json             # JSON output
  ./metrics.sh --period 7d        # Filter to last 7 days
  ./metrics.sh --period 90d       # Filter to last 90 days

Env vars:
  BOARD_OVERRIDE   Path to board JSON (skips read-board.sh)
  STATE_FILE       Path to delivery loop state file
  USAGE_DIR        Path to directory with per-card usage JSONs
HELP

# ── Parse args ──────────────────────────────────────────
OUTPUT_JSON=false
PERIOD="30d"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)   OUTPUT_JSON=true; shift ;;
    --period) PERIOD="$2"; shift 2 ;;
    *)        echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Parse period into days
PERIOD_DAYS="${PERIOD%d}"
if ! [[ "$PERIOD_DAYS" =~ ^[0-9]+$ ]]; then
  echo "Error: --period must be like 7d, 30d, 90d" >&2
  exit 1
fi

# ── Read board ──────────────────────────────────────────
if [[ -n "${BOARD_OVERRIDE:-}" ]]; then
  BOARD_JSON=$(cat "$BOARD_OVERRIDE")
else
  BOARD_JSON=$("$SCRIPT_DIR/read-board.sh" 2>/dev/null)
fi

# ── Count cards per column ──────────────────────────────
count_column() {
  local col="$1"
  echo "$BOARD_JSON" | jq --arg col "$col" '[.cards[] | select(.fields.Status == $col)] | length'
}

COL_BACKLOG=$(count_column "Backlog")
COL_READY=$(count_column "Ready")
COL_IN_PROGRESS=$(count_column "In Progress")
COL_IN_REVIEW=$(count_column "In Review")
COL_DONE=$(count_column "Done")

# ── Read state file for cycle times and rework ──────────
CYCLE_TIME_AVG=0
REWORK_RATE=0
TOTAL_CARDS_IN_STATE=0
REWORK_CARDS=0

if [[ -f "$STATE_FILE" ]]; then
  # Count total cards and rework cards (loop_count > 0)
  TOTAL_CARDS_IN_STATE=$(jq '[.cards | to_entries[]] | length' "$STATE_FILE" 2>/dev/null || echo 0)
  REWORK_CARDS=$(jq '[.cards | to_entries[] | select(.value.loop_count > 0)] | length' "$STATE_FILE" 2>/dev/null || echo 0)

  if [[ "$TOTAL_CARDS_IN_STATE" -gt 0 ]]; then
    REWORK_RATE=$(echo "scale=1; $REWORK_CARDS * 100 / $TOTAL_CARDS_IN_STATE" | bc)
  fi

  # Calculate cycle time from cards that have started_at and completed_at
  # These fields are set by state.sh when cards move through the pipeline
  CYCLE_TIMES=$(jq -r '
    [.cards | to_entries[] |
     select(.value.started_at != null and .value.completed_at != null) |
     .value |
     {started: .started_at, completed: .completed_at}
    ] | if length == 0 then empty else . end
  ' "$STATE_FILE" 2>/dev/null || echo "")

  if [[ -n "$CYCLE_TIMES" && "$CYCLE_TIMES" != "null" ]]; then
    # Use jq to compute average cycle time in hours from ISO timestamps
    CYCLE_TIME_AVG=$(echo "$CYCLE_TIMES" | jq '
      [.[] |
       ((.completed | fromdateiso8601) -
        (.started  | fromdateiso8601)) / 3600
      ] | if length > 0 then (add / length * 10 | round / 10) else 0 end
    ' 2>/dev/null || echo "0")
  fi
fi

# ── Compute throughput ──────────────────────────────────
# Done cards / period in weeks
WEEKS=$(echo "scale=2; $PERIOD_DAYS / 7" | bc)
if [[ $(echo "$WEEKS > 0" | bc) -eq 1 ]]; then
  THROUGHPUT=$(echo "scale=1; $COL_DONE / $WEEKS" | bc)
else
  THROUGHPUT=0
fi

# ── Aggregate costs from usage dir ──────────────────────
TOTAL_COST="0"
CARD_COUNT_WITH_COST=0

DEAD_LETTER_COST=0
SHIPPED_COST=0
if [[ -d "$USAGE_DIR" ]]; then
  for f in "$USAGE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    CARD_COST=$(jq '.totals.cost_usd // 0' "$f" 2>/dev/null || echo 0)
    CARD_NUM=$(basename "$f" .json)
    # Classify: was this card dead-lettered?
    DEAD=""
    if [[ -n "$CARD_NUM" && "$CARD_NUM" != "0" ]]; then
      DEAD=$(gh issue view "$CARD_NUM" --repo "$REPO" --json labels --jq 'any(.labels[]; .name == "dead-letter")' 2>/dev/null || echo "false")
    fi
    if [[ "$DEAD" == "true" ]]; then
      DEAD_LETTER_COST=$(echo "scale=6; $DEAD_LETTER_COST + $CARD_COST" | bc)
    else
      SHIPPED_COST=$(echo "scale=6; $SHIPPED_COST + $CARD_COST" | bc)
    fi
    TOTAL_COST=$(echo "scale=6; $TOTAL_COST + $CARD_COST" | bc)
    CARD_COUNT_WITH_COST=$((CARD_COUNT_WITH_COST + 1))
  done
fi

if [[ "$CARD_COUNT_WITH_COST" -gt 0 ]]; then
  AVG_COST=$(echo "scale=2; $TOTAL_COST / $CARD_COUNT_WITH_COST" | bc)
else
  AVG_COST="0"
fi

# Format total cost to 2 decimal places
TOTAL_COST=$(echo "scale=2; $TOTAL_COST / 1" | bc)
DEAD_LETTER_COST=$(echo "scale=2; $DEAD_LETTER_COST / 1" | bc)
SHIPPED_COST=$(echo "scale=2; $SHIPPED_COST / 1" | bc)
DEAD_LETTER_PCT=0
if [[ "$(echo "$TOTAL_COST > 0" | bc)" -eq 1 ]]; then
  DEAD_LETTER_PCT=$(echo "scale=1; $DEAD_LETTER_COST * 100 / $TOTAL_COST" | bc)
fi

# ── Approval-wait timings ───────────────────────────────
# How long do design-approval and merge-approval emails sit before the user
# acts? Read sent (.sent_at) timestamps from queue files alongside the
# corresponding approval label events on the issue. This is the most direct
# measure of where the loop's wall-clock time goes.
QUEUE_DIR="${EPIC_EMAIL_QUEUE_DIR:-/tmp/helix-epic-emails-pending}"
DESIGN_WAITS=()
MERGE_WAITS=()
calc_wait_hours() {
  local sent_iso="$1" acted_iso="$2"
  if [[ -z "$sent_iso" || "$sent_iso" == "null" || -z "$acted_iso" || "$acted_iso" == "null" ]]; then
    echo ""
    return
  fi
  local s a
  s=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$sent_iso" +%s 2>/dev/null || echo 0)
  a=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$acted_iso" +%s 2>/dev/null || echo 0)
  [[ "$s" -eq 0 || "$a" -eq 0 || "$a" -le "$s" ]] && { echo ""; return; }
  echo $(( (a - s) / 3600 ))
}
if [[ -d "$QUEUE_DIR" ]]; then
  for f in "$QUEUE_DIR"/design-*.json; do
    [[ -f "$f" ]] || continue
    card=$(jq -r '.card // 0' "$f" 2>/dev/null)
    sent=$(jq -r '.created_at // ""' "$f" 2>/dev/null)
    [[ -z "$card" || "$card" == "0" ]] && continue
    label_event=$(gh api "repos/${REPO}/issues/${card}/events" 2>/dev/null \
      | jq -r '[.[] | select(.event=="labeled" and .label.name=="epic-approved")][0].created_at // ""' 2>/dev/null || echo "")
    h=$(calc_wait_hours "$sent" "$label_event")
    [[ -n "$h" ]] && DESIGN_WAITS+=("$h")
  done
  for f in "$QUEUE_DIR"/epic-*.json; do
    [[ -f "$f" ]] || continue
    pr=$(jq -r '.last_pr // 0' "$f" 2>/dev/null)
    sent=$(jq -r '.created_at // ""' "$f" 2>/dev/null)
    [[ -z "$pr" || "$pr" == "0" ]] && continue
    label_event=$(gh api "repos/${REPO}/issues/${pr}/events" 2>/dev/null \
      | jq -r '[.[] | select(.event=="labeled" and (.label.name=="user-approved" or .label.name=="epic-final-approved"))][0].created_at // ""' 2>/dev/null || echo "")
    h=$(calc_wait_hours "$sent" "$label_event")
    [[ -n "$h" ]] && MERGE_WAITS+=("$h")
  done
fi

median_p95() {
  # echoes "median p95"
  local values=("$@")
  if [[ ${#values[@]} -eq 0 ]]; then echo "- -"; return; fi
  local sorted
  sorted=$(printf '%s\n' "${values[@]}" | sort -n)
  local count="${#values[@]}"
  local median_idx=$(( count / 2 ))
  local p95_idx=$(( count * 95 / 100 ))
  [[ "$p95_idx" -ge "$count" ]] && p95_idx=$(( count - 1 ))
  local m p
  m=$(echo "$sorted" | sed -n "$((median_idx + 1))p")
  p=$(echo "$sorted" | sed -n "$((p95_idx + 1))p")
  echo "$m $p"
}
read -r DESIGN_WAIT_MEDIAN DESIGN_WAIT_P95 < <(median_p95 "${DESIGN_WAITS[@]+"${DESIGN_WAITS[@]}"}")
read -r MERGE_WAIT_MEDIAN MERGE_WAIT_P95 < <(median_p95 "${MERGE_WAITS[@]+"${MERGE_WAITS[@]}"}")

# ── Output ──────────────────────────────────────────────
if [[ "$OUTPUT_JSON" == "true" ]]; then
  jq -n \
    --argjson cycle_time "$CYCLE_TIME_AVG" \
    --argjson throughput "$THROUGHPUT" \
    --argjson rework "$REWORK_RATE" \
    --argjson avg_cost "$AVG_COST" \
    --argjson total_cost "$TOTAL_COST" \
    --argjson backlog "$COL_BACKLOG" \
    --argjson ready "$COL_READY" \
    --argjson in_progress "$COL_IN_PROGRESS" \
    --argjson in_review "$COL_IN_REVIEW" \
    --argjson done "$COL_DONE" \
    --argjson wip_prog "$WIP_IN_PROGRESS" \
    --argjson wip_rev "$WIP_IN_REVIEW" \
    '{
      cycle_time_avg_hours: $cycle_time,
      throughput_per_week: $throughput,
      rework_rate_pct: $rework,
      avg_cost_per_card_usd: $avg_cost,
      total_cost_30d_usd: $total_cost,
      by_column: {
        Backlog: $backlog,
        Ready: $ready,
        "In Progress": $in_progress,
        "In Review": $in_review,
        Done: $done
      },
      wip_status: {
        in_progress: ("\($in_progress)/\($wip_prog)"),
        in_review: ("\($in_review)/\($wip_rev)")
      },
      approval_wait_hours: {
        design: { median: "'"$DESIGN_WAIT_MEDIAN"'", p95: "'"$DESIGN_WAIT_P95"'", samples: '"${#DESIGN_WAITS[@]}"' },
        merge:  { median: "'"$MERGE_WAIT_MEDIAN"'",  p95: "'"$MERGE_WAIT_P95"'",  samples: '"${#MERGE_WAITS[@]}"' }
      }
    }'
else
  echo "Delivery Metrics (last ${PERIOD_DAYS} days)"
  echo "  Cycle time:  ${CYCLE_TIME_AVG}h avg (Ready → Done)"
  echo "  Throughput:  ${THROUGHPUT} cards/week"
  echo "  Rework rate: ${REWORK_RATE}%"
  echo "  Avg cost:    \$${AVG_COST}/card"
  echo "  Total cost:  \$${TOTAL_COST}  (shipped \$${SHIPPED_COST} + dead-letter \$${DEAD_LETTER_COST}, ${DEAD_LETTER_PCT}% wasted)"
  echo "  Board:       ${COL_BACKLOG} Backlog | ${COL_READY} Ready | ${COL_IN_PROGRESS} In Progress | ${COL_IN_REVIEW} In Review | ${COL_DONE} Done"
  echo "  WIP:         In Progress ${COL_IN_PROGRESS}/${WIP_IN_PROGRESS} | In Review ${COL_IN_REVIEW}/${WIP_IN_REVIEW}"
  echo "  Design-approval wait:  median ${DESIGN_WAIT_MEDIAN}h, p95 ${DESIGN_WAIT_P95}h (${#DESIGN_WAITS[@]} samples)"
  echo "  Merge-approval wait:   median ${MERGE_WAIT_MEDIAN}h, p95 ${MERGE_WAIT_P95}h (${#MERGE_WAITS[@]} samples)"
fi
