#!/bin/bash
# Integration test: dispatcher → run-agent flow (no real APIs or LLMs)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"

PASS=0; FAIL=0
assert() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else echo "FAIL: $3 — expected '$2', got '$1'"; FAIL=$((FAIL+1)); fi; }
assert_contains() { if echo "$1" | grep -q "$2"; then PASS=$((PASS+1)); else echo "FAIL: $3 — output does not contain '$2'"; FAIL=$((FAIL+1)); fi; }

# Setup temp files
export STATE_FILE="/tmp/test-integration-state-$$.json"
export BOARD_OVERRIDE="/tmp/test-integration-board-$$.json"
export USAGE_DIR="/tmp/test-integration-usage-$$"
export DRY_RUN=1
mkdir -p "$USAGE_DIR"
trap "rm -rf $STATE_FILE $BOARD_OVERRIDE $USAGE_DIR" EXIT

# ── Scenario 1: Ready card → dispatcher picks planner → run-agent prepares prompt ──
echo '{"cards":{}}' > "$STATE_FILE"
cat > "$BOARD_OVERRIDE" <<'JSON'
{
  "cards": [{
    "item_id": "I1",
    "issue_number": 137,
    "title": "Surface CognitiveAction lifecycle in Insights tab UI",
    "url": "https://github.com/amonick12/helix/issues/137",
    "state": "OPEN",
    "labels": [],
    "recent_comments": [],
    "fields": {"Status": "Ready", "Priority": "P1"}
  }]
}
JSON

# Step 1: dispatcher should pick planner for card 137
DISPATCH=$(bash "$SCRIPT_DIR/dispatcher.sh" --dry-run 2>/dev/null)
AGENT=$(echo "$DISPATCH" | jq -r '.agent')
CARD=$(echo "$DISPATCH" | jq -r '.card')
MODEL=$(echo "$DISPATCH" | jq -r '.model')
assert "$AGENT" "planner" "Scenario 1: dispatcher picks planner"
assert "$CARD" "137" "Scenario 1: dispatcher picks card 137"
assert "$MODEL" "opus" "Scenario 1: model is opus for planner"

# Step 2: run-agent prepare should construct a prompt
PROMPT=$(bash "$SCRIPT_DIR/run-agent.sh" prepare planner --card 137 2>/dev/null)
assert_contains "$PROMPT" "137" "Scenario 1: prompt mentions card 137"
assert_contains "$PROMPT" "CognitiveAction" "Scenario 1: prompt contains card title"

# ── Scenario 2: In Progress + draft PR → dispatcher picks builder (rule 5) ──
# With the verifier split into reviewer/tester, dispatch now uses PR state
# (draft/ready) and labels (code-review-approved, visual-qa-approved).
# In test mode, gh pr view fails → fallback {draft:true, rework:false} → rule 5 (builder).
cat > "$BOARD_OVERRIDE" <<'JSON'
{
  "cards": [{
    "item_id": "I1",
    "issue_number": 137,
    "title": "Surface CognitiveAction lifecycle",
    "url": "https://github.com/amonick12/helix/issues/137",
    "state": "OPEN",
    "labels": [],
    "recent_comments": [],
    "fields": {"Status": "In progress", "Priority": "P1", "OwnerAgent": "Builder", "PR URL": "https://github.com/amonick12/helix/pull/99999"}
  }]
}
JSON
echo '{"cards":{"137":{"last_agent":"builder"}}}' > "$STATE_FILE"

DISPATCH=$(bash "$SCRIPT_DIR/dispatcher.sh" --dry-run 2>/dev/null)
AGENT=$(echo "$DISPATCH" | jq -r '.agent')
assert "$AGENT" "builder" "Scenario 2: draft PR fallback → builder (rule 5)"

# ── Scenario 3: user-approved label → dispatcher picks releaser ──
cat > "$BOARD_OVERRIDE" <<'JSON'
{
  "cards": [{
    "item_id": "I1",
    "issue_number": 137,
    "title": "Surface CognitiveAction lifecycle",
    "url": "https://github.com/amonick12/helix/issues/137",
    "state": "OPEN",
    "labels": ["user-approved"],
    "recent_comments": [],
    "fields": {"Status": "In review", "Priority": "P1", "PR URL": "https://github.com/amonick12/helix/pull/87"}
  }]
}
JSON
echo '{"cards":{}}' > "$STATE_FILE"

DISPATCH=$(bash "$SCRIPT_DIR/dispatcher.sh" --dry-run 2>/dev/null)
AGENT=$(echo "$DISPATCH" | jq -r '.agent')
assert "$AGENT" "releaser" "Scenario 3: user-approved → releaser"

# ── Scenario 4: state.sh set/get cycle ──
echo '{"cards":{}}' > "$STATE_FILE"
bash "$SCRIPT_DIR/state.sh" set 42 last_agent planner 2>/dev/null
bash "$SCRIPT_DIR/state.sh" set 42 handoff_ready true 2>/dev/null
bash "$SCRIPT_DIR/state.sh" set 42 handoff_from planner 2>/dev/null
HANDOFF_READY=$(bash "$SCRIPT_DIR/state.sh" get 42 handoff_ready 2>/dev/null)
assert "$HANDOFF_READY" "true" "Scenario 4: set handoff_ready=true"

bash "$SCRIPT_DIR/state.sh" set 42 last_agent builder 2>/dev/null
bash "$SCRIPT_DIR/state.sh" set 42 handoff_ready false 2>/dev/null
LAST_AGENT=$(bash "$SCRIPT_DIR/state.sh" get 42 last_agent 2>/dev/null)
assert "$LAST_AGENT" "builder" "Scenario 4: set last_agent=builder"

# ── Scenario 5: track-usage start/end cycle ──
bash "$SCRIPT_DIR/track-usage.sh" start --card 42 --agent builder 2>/dev/null
bash "$SCRIPT_DIR/track-usage.sh" end --card 42 --agent builder --input-tokens 50000 --output-tokens 15000 --model opus 2>/dev/null
CARD_COST=$(bash "$SCRIPT_DIR/track-usage.sh" card --card 42 2>/dev/null | jq -r '.totals.cost_usd')
# Cost: 50000/1M * 15 + 15000/1M * 75 = 0.75 + 1.125 = 1.875
assert_contains "$CARD_COST" "1.87" "Scenario 5: cost calculation correct"

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
