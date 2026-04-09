#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"

# Override STATE_FILE for test isolation
export STATE_FILE="/tmp/test-delivery-loop-state-$$.json"
rm -f "$STATE_FILE"
trap 'rm -f "$STATE_FILE"' EXIT

source "$SCRIPT_DIR/config.sh"

STATE="$SCRIPT_DIR/state.sh"

PASS=0; FAIL=0
assert() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $3 — expected '$2', got '$1'"
    FAIL=$((FAIL+1))
  fi
}

# ── Test: state file auto-created ────────────────────────
$STATE get 999 2>/dev/null || true
assert "$(jq -r '.cards | length' "$STATE_FILE" 2>/dev/null || echo -1)" "0" "state file auto-created with empty cards"

# ── Test: set + get ──────────────────────────────────────
$STATE set 137 last_agent planner 2>/dev/null
RESULT=$($STATE get 137 last_agent 2>/dev/null)
assert "$RESULT" "planner" "set and get last_agent"

# ── Test: set overwrites ─────────────────────────────────
$STATE set 137 last_agent builder 2>/dev/null
RESULT=$($STATE get 137 last_agent 2>/dev/null)
assert "$RESULT" "builder" "set overwrites previous value"

# ── Test: get full card ──────────────────────────────────
CARD_JSON=$($STATE get 137 2>/dev/null)
AGENT=$(echo "$CARD_JSON" | jq -r '.last_agent')
assert "$AGENT" "builder" "get full card returns JSON with last_agent"

# ── Test: get nonexistent card ───────────────────────────
EMPTY=$($STATE get 999 2>/dev/null)
assert "$EMPTY" "{}" "get nonexistent card returns empty object"

# ── Test: get nonexistent field ──────────────────────────
EMPTY_FIELD=$($STATE get 137 nonexistent 2>/dev/null || echo "")
assert "$EMPTY_FIELD" "" "get nonexistent field returns empty"

# ── Test: set multiple fields ────────────────────────────
$STATE set 137 handoff_ready "true" 2>/dev/null
$STATE set 137 handoff_from "planner" 2>/dev/null
HR=$($STATE get 137 handoff_ready 2>/dev/null)
HF=$($STATE get 137 handoff_from 2>/dev/null)
assert "$HR" "true" "set handoff_ready"
assert "$HF" "planner" "set handoff_from"

# ── Test: clear ──────────────────────────────────────────
$STATE set 200 last_agent scout 2>/dev/null
$STATE clear 200 2>/dev/null
CLEARED=$($STATE get 200 2>/dev/null)
assert "$CLEARED" "{}" "clear removes card state"

# ── Test: set-json ───────────────────────────────────────
$STATE set-json 300 screenshot_paths '{"before":"/tmp/b.png","after":"/tmp/a.png"}' 2>/dev/null
SP=$($STATE get 300 screenshot_paths 2>/dev/null)
BEFORE=$(echo "$SP" | jq -r '.before' 2>/dev/null || echo "")
assert "$BEFORE" "/tmp/b.png" "set-json stores complex JSON"

# ── Test: list ───────────────────────────────────────────
$STATE set 400 last_agent designer 2>/dev/null
LIST_OUTPUT=$($STATE list 2>/dev/null)
assert "$(echo "$LIST_OUTPUT" | grep -c "137")" "1" "list includes card 137"
assert "$(echo "$LIST_OUTPUT" | grep -c "400")" "1" "list includes card 400"

# ── Test: last_updated auto-set ──────────────────────────
UPDATED=$($STATE get 137 last_updated 2>/dev/null)
assert "$(echo "$UPDATED" | grep -c "202")" "1" "last_updated has timestamp"

# ── Report ───────────────────────────────────────────────
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
