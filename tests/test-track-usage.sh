#!/bin/bash
# test-track-usage.sh — Tests for track-usage.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
TRACK="$SCRIPT_DIR/track-usage.sh"

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
  # Compare floating point values within tolerance
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

# ── Setup temp dir ──────────────────────────────────────
export USAGE_DIR="/tmp/test-delivery-usage-$$"
mkdir -p "$USAGE_DIR"
trap 'rm -rf "$USAGE_DIR"' EXIT

# ── Test 1: start creates usage file with open run ─────
"$TRACK" start --card 137 --agent planner 2>/dev/null

USAGE_FILE="$USAGE_DIR/137.json"
assert "$(test -f "$USAGE_FILE" && echo yes)" "yes" "start creates usage file"

AGENT=$(jq -r '.runs[0].agent' "$USAGE_FILE")
assert "$AGENT" "planner" "start records agent name"

ENDED=$(jq -r '.runs[0].ended' "$USAGE_FILE")
assert "$ENDED" "null" "start leaves ended as null"

STARTED=$(jq -r '.runs[0].started' "$USAGE_FILE")
assert "$(echo "$STARTED" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" "1" "start records ISO timestamp"

# ── Test 2: end updates the run with tokens + cost ─────
"$TRACK" end --card 137 --agent planner \
  --input-tokens 45000 --output-tokens 12000 --model opus 2>/dev/null

INPUT=$(jq '.runs[0].input_tokens' "$USAGE_FILE")
assert "$INPUT" "45000" "end records input tokens"

OUTPUT=$(jq '.runs[0].output_tokens' "$USAGE_FILE")
assert "$OUTPUT" "12000" "end records output tokens"

MODEL=$(jq -r '.runs[0].model' "$USAGE_FILE")
assert "$MODEL" "opus" "end records model"

ENDED_AFTER=$(jq -r '.runs[0].ended' "$USAGE_FILE")
assert "$(echo "$ENDED_AFTER" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" "1" "end records ended timestamp"

# ── Test 3: cost math verification ─────────────────────
# 45000 input at opus rate ($15/1M) = 45000/1000000 * 15 = $0.675
# 12000 output at opus rate ($75/1M) = 12000/1000000 * 75 = $0.90
# Total = $1.575
COST=$(jq '.runs[0].cost_usd' "$USAGE_FILE")
assert_near "$COST" "1.575" "0.001" "cost calculation (45k in + 12k out opus)"

# ── Test 4: totals are updated ─────────────────────────
TOTAL_INPUT=$(jq '.totals.input_tokens' "$USAGE_FILE")
assert "$TOTAL_INPUT" "45000" "totals input tokens"

TOTAL_OUTPUT=$(jq '.totals.output_tokens' "$USAGE_FILE")
assert "$TOTAL_OUTPUT" "12000" "totals output tokens"

TOTAL_COST=$(jq '.totals.cost_usd' "$USAGE_FILE")
assert_near "$TOTAL_COST" "1.575" "0.001" "totals cost"

# ── Test 5: second run accumulates ─────────────────────
"$TRACK" start --card 137 --agent builder 2>/dev/null
"$TRACK" end --card 137 --agent builder \
  --input-tokens 100000 --output-tokens 25000 --model sonnet 2>/dev/null

# Sonnet: 100000/1M * 3 = 0.30, 25000/1M * 15 = 0.375, total = 0.675
RUN2_COST=$(jq '.runs[1].cost_usd' "$USAGE_FILE")
assert_near "$RUN2_COST" "0.675" "0.001" "second run cost (sonnet)"

NUM_RUNS=$(jq '.runs | length' "$USAGE_FILE")
assert "$NUM_RUNS" "2" "two runs recorded"

TOTAL_INPUT2=$(jq '.totals.input_tokens' "$USAGE_FILE")
assert "$TOTAL_INPUT2" "145000" "accumulated input tokens"

TOTAL_COST2=$(jq '.totals.cost_usd' "$USAGE_FILE")
assert_near "$TOTAL_COST2" "2.25" "0.001" "accumulated cost"

# ── Test 6: card command outputs JSON ──────────────────
CARD_OUTPUT=$("$TRACK" card --card 137 2>/dev/null)
CARD_NUM=$(echo "$CARD_OUTPUT" | jq '.card')
assert "$CARD_NUM" "137" "card command returns card data"

CARD_RUNS=$(echo "$CARD_OUTPUT" | jq '.runs | length')
assert "$CARD_RUNS" "2" "card command shows all runs"

# ── Test 7: summary command ────────────────────────────
# Add a second card
"$TRACK" start --card 200 --agent designer 2>/dev/null
"$TRACK" end --card 200 --agent designer \
  --input-tokens 32000 --output-tokens 8500 --model sonnet 2>/dev/null

SUMMARY=$("$TRACK" summary 2>/dev/null)
assert_contains "$SUMMARY" "#137" "summary includes card 137"
assert_contains "$SUMMARY" "#200" "summary includes card 200"
assert_contains "$SUMMARY" "Grand totals" "summary has grand totals line"

# ── Test 8: post in DRY_RUN mode ──────────────────────
POST_OUTPUT=$(DRY_RUN=true "$TRACK" post --card 137 2>/dev/null)
assert_contains "$POST_OUTPUT" "Token Usage" "post generates markdown header"
assert_contains "$POST_OUTPUT" "planner" "post includes planner run"
assert_contains "$POST_OUTPUT" "builder" "post includes builder run"
assert_contains "$POST_OUTPUT" "Totals" "post includes totals"

# ── Test 9: haiku cost rates ─────────────────────────
"$TRACK" start --card 300 --agent releaser 2>/dev/null
"$TRACK" end --card 300 --agent releaser \
  --input-tokens 1000000 --output-tokens 500000 --model haiku 2>/dev/null

# Haiku: 1M/1M * 0.80 = 0.80, 500k/1M * 4.00 = 2.00, total = 2.80
HAIKU_COST=$(jq '.runs[0].cost_usd' "$USAGE_DIR/300.json")
assert_near "$HAIKU_COST" "2.80" "0.01" "haiku cost calculation"

# ── Results ─────────────────────────────────────────────
echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
