#!/bin/bash
# test-run-agent.sh — Tests for run-agent.sh Phase 1 (prepare).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"

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
    FAIL=$((FAIL+1))
  fi
}
assert_nonzero_exit() {
  if [[ "$1" -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $2 — expected non-zero exit, got 0"
    FAIL=$((FAIL+1))
  fi
}

# Use temp files for state and board
export STATE_FILE="/tmp/test-run-agent-state-$$.json"
export BOARD_OVERRIDE="/tmp/test-run-agent-board-$$.json"
export USAGE_DIR="/tmp/test-run-agent-usage-$$"
export DRY_RUN=1
mkdir -p "$USAGE_DIR"
trap "rm -rf $STATE_FILE $BOARD_OVERRIDE $USAGE_DIR" EXIT

# Initialize state
echo '{"cards":{}}' > "$STATE_FILE"

# Helper: create board JSON with a card
make_board() {
  echo "$1" > "$BOARD_OVERRIDE"
}

# ── Test 1: Missing phase ──────────────────────────────
OUTPUT=$(bash "$SCRIPT_DIR/run-agent.sh" 2>&1 || true)
EXIT_CODE=0
bash "$SCRIPT_DIR/run-agent.sh" 2>/dev/null || EXIT_CODE=$?
assert_nonzero_exit "$EXIT_CODE" "Missing phase exits non-zero"

# ── Test 2: Missing agent ──────────────────────────────
EXIT_CODE=0
bash "$SCRIPT_DIR/run-agent.sh" prepare 2>/dev/null || EXIT_CODE=$?
assert_nonzero_exit "$EXIT_CODE" "Missing agent exits non-zero"

# ── Test 3: Missing --card ─────────────────────────────
EXIT_CODE=0
bash "$SCRIPT_DIR/run-agent.sh" prepare builder 2>/dev/null || EXIT_CODE=$?
assert_nonzero_exit "$EXIT_CODE" "Missing --card exits non-zero"

# ── Test 4: Invalid agent name ─────────────────────────
EXIT_CODE=0
bash "$SCRIPT_DIR/run-agent.sh" prepare fakename --card 42 2>/dev/null || EXIT_CODE=$?
assert_nonzero_exit "$EXIT_CODE" "Invalid agent name exits non-zero"

# ── Test 5: Builder defaults to opus ───────────────────
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix navigation","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"In progress","Priority":"P1"}
  }]
}'
echo '{"cards":{}}' > "$STATE_FILE"
STDERR_OUTPUT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare builder --card 42 2>&1 >/dev/null || true)
MODEL_LINE=$(echo "$STDERR_OUTPUT" | grep "^MODEL=" || echo "")
MODEL_VAL=$(echo "$MODEL_LINE" | sed 's/MODEL=//')
assert "$MODEL_VAL" "opus" "Builder defaults to opus model"

# ── Test 6: Builder with --rework uses opus (best model when fixing mistakes) ──
STDERR_OUTPUT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare builder --card 42 --rework 2>&1 >/dev/null || true)
MODEL_LINE=$(echo "$STDERR_OUTPUT" | grep "^MODEL=" || echo "")
MODEL_VAL=$(echo "$MODEL_LINE" | sed 's/MODEL=//')
assert "$MODEL_VAL" "opus" "Builder --rework uses opus model"

# ── Test 7: --model override takes precedence ──────────
STDERR_OUTPUT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare builder --card 42 --model haiku 2>&1 >/dev/null || true)
MODEL_LINE=$(echo "$STDERR_OUTPUT" | grep "^MODEL=" || echo "")
MODEL_VAL=$(echo "$MODEL_LINE" | sed 's/MODEL=//')
assert "$MODEL_VAL" "haiku" "--model override to haiku"

# ── Test 8: --model override beats --rework ────────────
STDERR_OUTPUT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare builder --card 42 --rework --model opus 2>&1 >/dev/null || true)
MODEL_LINE=$(echo "$STDERR_OUTPUT" | grep "^MODEL=" || echo "")
MODEL_VAL=$(echo "$MODEL_LINE" | sed 's/MODEL=//')
assert "$MODEL_VAL" "opus" "--model override beats --rework"

# ── Test 9: Planner defaults to opus ───────────────────
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix navigation","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"Ready","Priority":"P1"}
  }]
}'
STDERR_OUTPUT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare planner --card 42 2>&1 >/dev/null || true)
MODEL_LINE=$(echo "$STDERR_OUTPUT" | grep "^MODEL=" || echo "")
MODEL_VAL=$(echo "$MODEL_LINE" | sed 's/MODEL=//')
assert "$MODEL_VAL" "opus" "Planner defaults to opus"

# ── Test 10a: Reviewer defaults to haiku (orchestrates Codex CLI; haiku is cheap) ──
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix navigation","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"In progress","Priority":"P1"}
  }]
}'
STDERR_OUTPUT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare reviewer --card 42 2>&1 >/dev/null || true)
MODEL_LINE=$(echo "$STDERR_OUTPUT" | grep "^MODEL=" || echo "")
MODEL_VAL=$(echo "$MODEL_LINE" | sed 's/MODEL=//')
assert "$MODEL_VAL" "haiku" "Reviewer's Claude orchestrator defaults to haiku (the actual review runs in OpenAI Codex CLI; Claude just shells out to it, so haiku is fine)"

# ── Test 10b: Tester defaults to sonnet ────────────────
STDERR_OUTPUT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare tester --card 42 2>&1 >/dev/null || true)
MODEL_LINE=$(echo "$STDERR_OUTPUT" | grep "^MODEL=" || echo "")
MODEL_VAL=$(echo "$MODEL_LINE" | sed 's/MODEL=//')
assert "$MODEL_VAL" "sonnet" "Tester defaults to sonnet"

# ── Test 11: Prompt contains card title ────────────────
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix navigation bar crash","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":["bug"],"recent_comments":[],
    "fields":{"Status":"In progress","Priority":"P0"}
  }]
}'
echo '{"cards":{}}' > "$STATE_FILE"
PROMPT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare builder --card 42 2>/dev/null)
assert_contains "$PROMPT" "Fix navigation bar crash" "Prompt contains card title"

# ── Test 12: Prompt contains card number ───────────────
assert_contains "$PROMPT" "#42" "Prompt contains card number"

# ── Test 13: Prompt contains agent instructions ────────
assert_contains "$PROMPT" "## Agent Instructions" "Prompt contains agent instructions section"

# ── Test 14: Prompt contains checklist from reference ──
assert_contains "$PROMPT" "Agent" "Prompt contains agent reference content"

# ── Test 15: Prompt is non-empty ───────────────────────
if [[ -n "$PROMPT" ]]; then
  PASS=$((PASS+1))
else
  echo "FAIL: Prompt is empty"
  FAIL=$((FAIL+1))
fi

# ── Test 16: Rework mode shows in prompt ───────────────
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix navigation bar crash","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"In progress","Priority":"P0","ReworkReason":"Build failure in module X"}
  }]
}'
PROMPT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare builder --card 42 --rework 2>/dev/null)
assert_contains "$PROMPT" "REWORK" "Rework mode shows in prompt"

# ── Test 17: State pickup is called ────────────────────
echo '{"cards":{}}' > "$STATE_FILE"
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Test card","url":"u",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"In progress","Priority":"P1"}
  }]
}'
bash "$SCRIPT_DIR/run-agent.sh" prepare builder --card 42 >/dev/null 2>&1 || true
# Check that state file was updated with the agent pickup
STATE_AGENT=$(jq -r '.cards["42"].last_agent // "none"' "$STATE_FILE" 2>/dev/null || echo "none")
assert "$STATE_AGENT" "builder" "State pickup records agent"

# ── Test 18: Scout model defaults to sonnet ────────────
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":0,"title":"Discovery","url":"",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"Backlog","Priority":"P3"}
  }]
}'
STDERR_OUTPUT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare scout --card 0 2>&1 >/dev/null || true)
MODEL_LINE=$(echo "$STDERR_OUTPUT" | grep "^MODEL=" || echo "")
MODEL_VAL=$(echo "$MODEL_LINE" | sed 's/MODEL=//')
assert "$MODEL_VAL" "sonnet" "Scout defaults to sonnet"

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
