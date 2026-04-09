#!/bin/bash
# test-metrics.sh — Tests for metrics.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
METRICS="$SCRIPT_DIR/metrics.sh"

# ── Test harness ────────────────────────────────────────
PASS=0; FAIL=0
assert() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $3 — expected '$2', got '$1'"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  if echo "$1" | grep -qF "$2"; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $3 — output does not contain '$2'"
    echo "  got: $1"
    FAIL=$((FAIL+1))
  fi
}

assert_near() {
  local actual="$1" expected="$2" tol="$3" label="$4"
  local diff
  diff=$(echo "scale=10; d = $actual - $expected; if (d < 0) -d else d" | bc)
  local ok
  ok=$(echo "$diff < $tol" | bc)
  if [[ "$ok" == "1" ]]; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $label — expected ~$expected (tol $tol), got $actual (diff $diff)"
    FAIL=$((FAIL+1))
  fi
}

# ── Setup temp fixtures ─────────────────────────────────
TMPDIR_TEST="/tmp/test-metrics-$$"
mkdir -p "$TMPDIR_TEST"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Mock board JSON ─────────────────────────────────────
BOARD_FILE="$TMPDIR_TEST/board.json"
cat > "$BOARD_FILE" <<'BOARD'
{
  "project": {"title": "Helix", "number": 3, "id": "test"},
  "cards": [
    {"item_id": "a1", "issue_number": 10, "title": "Card A", "fields": {"Status": "Backlog"}},
    {"item_id": "a2", "issue_number": 11, "title": "Card B", "fields": {"Status": "Ready"}},
    {"item_id": "a3", "issue_number": 12, "title": "Card C", "fields": {"Status": "Ready"}},
    {"item_id": "a4", "issue_number": 13, "title": "Card D", "fields": {"Status": "Ready"}},
    {"item_id": "a5", "issue_number": 14, "title": "Card E", "fields": {"Status": "In Progress"}},
    {"item_id": "a6", "issue_number": 15, "title": "Card F", "fields": {"Status": "In Review"}},
    {"item_id": "a7", "issue_number": 16, "title": "Card G", "fields": {"Status": "In Review"}},
    {"item_id": "a8", "issue_number": 17, "title": "Card H", "fields": {"Status": "Done"}},
    {"item_id": "a9", "issue_number": 18, "title": "Card I", "fields": {"Status": "Done"}},
    {"item_id": "a10", "issue_number": 19, "title": "Card J", "fields": {"Status": "Done"}},
    {"item_id": "a11", "issue_number": 20, "title": "Card K", "fields": {"Status": "Done"}},
    {"item_id": "a12", "issue_number": 21, "title": "Card L", "fields": {"Status": "Done"}}
  ]
}
BOARD

# ── Mock state file ─────────────────────────────────────
STATE_MOCK="$TMPDIR_TEST/state.json"
cat > "$STATE_MOCK" <<'STATE'
{
  "cards": {
    "17": {
      "last_agent": "builder",
      "last_updated": "2026-03-27T10:00:00Z",
      "handoff_ready": false,
      "handoff_from": null,
      "rework_target": null,
      "loop_count": 0,
      "started_at": "2026-03-27T06:00:00Z",
      "completed_at": "2026-03-27T10:00:00Z"
    },
    "18": {
      "last_agent": "builder",
      "last_updated": "2026-03-26T15:00:00Z",
      "handoff_ready": false,
      "handoff_from": null,
      "rework_target": null,
      "loop_count": 2,
      "started_at": "2026-03-26T09:00:00Z",
      "completed_at": "2026-03-26T15:00:00Z"
    },
    "19": {
      "last_agent": "tester",
      "last_updated": "2026-03-25T12:00:00Z",
      "handoff_ready": false,
      "handoff_from": null,
      "rework_target": null,
      "loop_count": 0,
      "started_at": "2026-03-25T08:00:00Z",
      "completed_at": "2026-03-25T12:00:00Z"
    },
    "20": {
      "last_agent": "builder",
      "last_updated": "2026-03-24T14:00:00Z",
      "handoff_ready": false,
      "handoff_from": null,
      "rework_target": null,
      "loop_count": 1,
      "started_at": "2026-03-24T10:00:00Z",
      "completed_at": "2026-03-24T14:00:00Z"
    },
    "14": {
      "last_agent": "builder",
      "last_updated": "2026-03-28T08:00:00Z",
      "handoff_ready": false,
      "handoff_from": null,
      "rework_target": null,
      "loop_count": 0
    }
  }
}
STATE

# ── Mock usage dir ──────────────────────────────────────
USAGE_MOCK="$TMPDIR_TEST/usage"
mkdir -p "$USAGE_MOCK"

# Card 17: cost $1.575
cat > "$USAGE_MOCK/17.json" <<'U1'
{
  "card": 17,
  "runs": [{"agent": "builder", "model": "opus", "input_tokens": 45000, "output_tokens": 12000, "cost_usd": 1.575, "started": "2026-03-27T06:00:00Z", "ended": "2026-03-27T10:00:00Z", "duration_sec": 14400}],
  "totals": {"input_tokens": 45000, "output_tokens": 12000, "cost_usd": 1.575, "duration_sec": 14400}
}
U1

# Card 18: cost $0.675 (two runs due to rework)
cat > "$USAGE_MOCK/18.json" <<'U2'
{
  "card": 18,
  "runs": [
    {"agent": "builder", "model": "sonnet", "input_tokens": 100000, "output_tokens": 25000, "cost_usd": 0.675, "started": "2026-03-26T09:00:00Z", "ended": "2026-03-26T12:00:00Z", "duration_sec": 10800},
    {"agent": "builder", "model": "sonnet", "input_tokens": 80000, "output_tokens": 20000, "cost_usd": 0.54, "started": "2026-03-26T13:00:00Z", "ended": "2026-03-26T15:00:00Z", "duration_sec": 7200}
  ],
  "totals": {"input_tokens": 180000, "output_tokens": 45000, "cost_usd": 1.215, "duration_sec": 18000}
}
U2

# Card 19: cost $2.80
cat > "$USAGE_MOCK/19.json" <<'U3'
{
  "card": 19,
  "runs": [{"agent": "tester", "model": "haiku", "input_tokens": 1000000, "output_tokens": 500000, "cost_usd": 2.80, "started": "2026-03-25T08:00:00Z", "ended": "2026-03-25T12:00:00Z", "duration_sec": 14400}],
  "totals": {"input_tokens": 1000000, "output_tokens": 500000, "cost_usd": 2.80, "duration_sec": 14400}
}
U3

# ── Export env vars ─────────────────────────────────────
export BOARD_OVERRIDE="$BOARD_FILE"
export STATE_FILE="$STATE_MOCK"
export USAGE_DIR="$USAGE_MOCK"

# ── Test 1: Column counts ──────────────────────────────
JSON_OUT=$("$METRICS" --json 2>/dev/null)

BACKLOG=$(echo "$JSON_OUT" | jq '.by_column.Backlog')
assert "$BACKLOG" "1" "Backlog count"

READY=$(echo "$JSON_OUT" | jq '.by_column.Ready')
assert "$READY" "3" "Ready count"

IN_PROG=$(echo "$JSON_OUT" | jq '.by_column["In Progress"]')
assert "$IN_PROG" "1" "In Progress count"

IN_REV=$(echo "$JSON_OUT" | jq '.by_column["In Review"]')
assert "$IN_REV" "2" "In Review count"

DONE=$(echo "$JSON_OUT" | jq '.by_column.Done')
assert "$DONE" "5" "Done count"

# ── Test 2: WIP status shows current/limit ─────────────
WIP_PROG=$(echo "$JSON_OUT" | jq -r '.wip_status.in_progress')
assert "$WIP_PROG" "1/6" "WIP In Progress current/limit"

WIP_REV=$(echo "$JSON_OUT" | jq -r '.wip_status.in_review')
assert "$WIP_REV" "2/5" "WIP In Review current/limit"

# ── Test 3: JSON output structure ───────────────────────
# Verify all expected top-level keys exist
KEYS=$(echo "$JSON_OUT" | jq -r 'keys[]' | sort | tr '\n' ',')
assert "$KEYS" "avg_cost_per_card_usd,by_column,cycle_time_avg_hours,rework_rate_pct,throughput_per_week,total_cost_30d_usd,wip_status," "JSON has all expected keys"

# ── Test 4: Human-readable output ───────────────────────
HUMAN_OUT=$("$METRICS" 2>/dev/null)

assert_contains "$HUMAN_OUT" "Delivery Metrics (last 30 days)" "human header"
assert_contains "$HUMAN_OUT" "Cycle time:" "human cycle time line"
assert_contains "$HUMAN_OUT" "Throughput:" "human throughput line"
assert_contains "$HUMAN_OUT" "Rework rate:" "human rework rate line"
assert_contains "$HUMAN_OUT" "Avg cost:" "human avg cost line"
assert_contains "$HUMAN_OUT" "Total cost:" "human total cost line"
assert_contains "$HUMAN_OUT" "Board:" "human board line"
assert_contains "$HUMAN_OUT" "WIP:" "human wip line"
assert_contains "$HUMAN_OUT" "1 Backlog" "human backlog count"
assert_contains "$HUMAN_OUT" "3 Ready" "human ready count"
assert_contains "$HUMAN_OUT" "1 In Progress" "human in progress count"
assert_contains "$HUMAN_OUT" "2 In Review" "human in review count"
assert_contains "$HUMAN_OUT" "5 Done" "human done count"

# ── Test 5: Rework rate calculation ─────────────────────
# State has 5 cards total; cards 18 and 20 have loop_count > 0 = 2 rework
# Rework rate = 2/5 * 100 = 40.0%
REWORK=$(echo "$JSON_OUT" | jq '.rework_rate_pct')
assert_near "$REWORK" "40.0" "0.1" "rework rate pct"

# ── Test 6: Cost aggregation ───────────────────────────
# Card 17: $1.575, Card 18: $1.215, Card 19: $2.80
# Total: $5.59, Avg: $5.59/3 = $1.86
TOTAL_COST=$(echo "$JSON_OUT" | jq '.total_cost_30d_usd')
assert_near "$TOTAL_COST" "5.59" "0.01" "total cost aggregation"

AVG_COST=$(echo "$JSON_OUT" | jq '.avg_cost_per_card_usd')
assert_near "$AVG_COST" "1.86" "0.01" "average cost per card"

# ── Test 7: Cycle time calculation ──────────────────────
# Card 17: 4h, Card 18: 6h, Card 19: 4h, Card 20: 4h
# Average: (4+6+4+4)/4 = 4.5h
CYCLE=$(echo "$JSON_OUT" | jq '.cycle_time_avg_hours')
assert_near "$CYCLE" "4.5" "0.1" "cycle time average"

# ── Test 8: Throughput calculation ──────────────────────
# 5 Done cards / (30/7) weeks = 5/4.28 = 1.1 cards/week
THROUGHPUT=$(echo "$JSON_OUT" | jq '.throughput_per_week')
assert_near "$THROUGHPUT" "1.1" "0.2" "throughput per week"

# ── Test 9: --period flag changes header ────────────────
HUMAN_7D=$("$METRICS" --period 7d 2>/dev/null)
assert_contains "$HUMAN_7D" "last 7 days" "period 7d in header"

# ── Test 10: Empty state file ──────────────────────────
EMPTY_STATE="$TMPDIR_TEST/empty-state.json"
echo '{"cards":{}}' > "$EMPTY_STATE"
export STATE_FILE="$EMPTY_STATE"

EMPTY_JSON=$("$METRICS" --json 2>/dev/null)
EMPTY_REWORK=$(echo "$EMPTY_JSON" | jq '.rework_rate_pct')
assert "$EMPTY_REWORK" "0" "rework rate zero when no cards in state"

EMPTY_CYCLE=$(echo "$EMPTY_JSON" | jq '.cycle_time_avg_hours')
assert "$EMPTY_CYCLE" "0" "cycle time zero when no cards in state"

# ── Test 11: Empty usage dir ───────────────────────────
EMPTY_USAGE="$TMPDIR_TEST/empty-usage"
mkdir -p "$EMPTY_USAGE"
export USAGE_DIR="$EMPTY_USAGE"

EMPTY_COST_JSON=$("$METRICS" --json 2>/dev/null)
EMPTY_TOTAL=$(echo "$EMPTY_COST_JSON" | jq '.total_cost_30d_usd')
assert "$EMPTY_TOTAL" "0" "total cost zero with no usage files"

EMPTY_AVG=$(echo "$EMPTY_COST_JSON" | jq '.avg_cost_per_card_usd')
assert "$EMPTY_AVG" "0" "avg cost zero with no usage files"

# ── Results ─────────────────────────────────────────────
echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
