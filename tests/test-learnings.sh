#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"

# Override LEARNINGS_FILE for test isolation
export LEARNINGS_FILE="/tmp/test-delivery-loop-learnings-$$.json"
rm -f "$LEARNINGS_FILE"
trap 'rm -f "$LEARNINGS_FILE"' EXIT

export DRY_RUN=1

source "$SCRIPT_DIR/config.sh"

LEARNINGS="$SCRIPT_DIR/learnings.sh"

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
  if echo "$1" | grep -q "$2"; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $3 — expected output to contain '$2', got '$1'"
    FAIL=$((FAIL+1))
  fi
}

assert_json_length() {
  local actual
  actual=$(echo "$1" | jq "$2 | length")
  if [[ "$actual" == "$3" ]]; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $4 — expected length $3, got $actual"
    FAIL=$((FAIL+1))
  fi
}

# ── Test: record creates file and stores learning ──────────
rm -f "$LEARNINGS_FILE"
RESULT=$($LEARNINGS record --card 42 --agent reviewer --type gate-failure \
  --lesson "Gate 4 failed: missing do/catch" \
  --context "Builder used try?" \
  --resolution "Wrapped in do/catch" \
  --tags "persistence,error-handling" 2>/dev/null)
assert_contains "$RESULT" '"id":1' "record returns id=1"
assert "$(jq '.learnings | length' "$LEARNINGS_FILE")" "1" "record creates one learning"
assert "$(jq -r '.learnings[0].agent' "$LEARNINGS_FILE")" "reviewer" "record stores correct agent"
assert "$(jq -r '.learnings[0].type' "$LEARNINGS_FILE")" "gate-failure" "record stores correct type"
assert "$(jq -r '.learnings[0].lesson' "$LEARNINGS_FILE")" "Gate 4 failed: missing do/catch" "record stores lesson"
assert "$(jq -r '.learnings[0].context' "$LEARNINGS_FILE")" "Builder used try?" "record stores context"
assert "$(jq -r '.learnings[0].resolution' "$LEARNINGS_FILE")" "Wrapped in do/catch" "record stores resolution"
assert "$(jq '.learnings[0].tags | length' "$LEARNINGS_FILE")" "2" "record stores tags"

# ── Test: record increments id ─────────────────────────────
RESULT=$($LEARNINGS record --card 43 --agent builder --type pattern \
  --lesson "Used protocol witness for testability" 2>/dev/null)
assert_contains "$RESULT" '"id":2' "second record gets id=2"
assert "$(jq '.learnings | length' "$LEARNINGS_FILE")" "2" "now two learnings"

# ── Test: record validates agent ───────────────────────────
if $LEARNINGS record --card 1 --agent invalid --type pattern --lesson "test" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "FAIL: record should reject invalid agent"
else
  PASS=$((PASS+1))
fi

# ── Test: record validates type ────────────────────────────
if $LEARNINGS record --card 1 --agent builder --type invalid --lesson "test" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "FAIL: record should reject invalid type"
else
  PASS=$((PASS+1))
fi

# ── Test: record requires mandatory fields ─────────────────
if $LEARNINGS record --card 1 --agent builder 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "FAIL: record should require --type and --lesson"
else
  PASS=$((PASS+1))
fi

# ── Test: query filters by agent ───────────────────────────
RESULT=$($LEARNINGS query --agent reviewer 2>/dev/null)
assert_json_length "$RESULT" "." "1" "query --agent reviewer returns 1 result"
assert "$(echo "$RESULT" | jq -r '.[0].agent')" "reviewer" "query returns correct agent"

RESULT=$($LEARNINGS query --agent builder 2>/dev/null)
assert_json_length "$RESULT" "." "1" "query --agent builder returns 1 result"

# ── Test: query filters by agent + type ────────────────────
RESULT=$($LEARNINGS query --agent reviewer --type gate-failure 2>/dev/null)
assert_json_length "$RESULT" "." "1" "query --agent reviewer --type gate-failure returns 1"

RESULT=$($LEARNINGS query --agent reviewer --type pattern 2>/dev/null)
assert_json_length "$RESULT" "." "0" "query --agent reviewer --type pattern returns 0"

# ── Test: query limit ──────────────────────────────────────
# Add more learnings
for i in 3 4 5 6 7; do
  $LEARNINGS record --card $((40 + i)) --agent reviewer --type gate-failure \
    --lesson "Learning $i" 2>/dev/null >/dev/null
done

RESULT=$($LEARNINGS query --agent reviewer --limit 3 2>/dev/null)
assert_json_length "$RESULT" "." "3" "query --limit 3 returns exactly 3"

RESULT=$($LEARNINGS query --agent reviewer --limit 10 2>/dev/null)
assert_json_length "$RESULT" "." "6" "query --limit 10 returns all 6 (not more)"

# ── Test: query returns most recent first ──────────────────
RESULT=$($LEARNINGS query --agent reviewer --limit 1 2>/dev/null)
assert "$(echo "$RESULT" | jq -r '.[0].lesson')" "Learning 7" "query returns most recent first"

# ── Test: stats ────────────────────────────────────────────
RESULT=$($LEARNINGS stats 2>/dev/null)
assert "$(echo "$RESULT" | jq '.total')" "7" "stats total is 7"
assert "$(echo "$RESULT" | jq '.by_type["gate-failure"]')" "6" "stats by_type gate-failure is 6"
assert "$(echo "$RESULT" | jq '.by_type["pattern"]')" "1" "stats by_type pattern is 1"
assert "$(echo "$RESULT" | jq '.by_agent["reviewer"]')" "6" "stats by_agent reviewer is 6"
assert "$(echo "$RESULT" | jq '.by_agent["builder"]')" "1" "stats by_agent builder is 1"

# ── Test: prune by age ─────────────────────────────────────
# Manually backdate some learnings to test prune
jq '.learnings[0].created = "2025-01-01T00:00:00Z" |
    .learnings[1].created = "2025-01-01T00:00:00Z"' \
  "$LEARNINGS_FILE" > "${LEARNINGS_FILE}.tmp" && mv "${LEARNINGS_FILE}.tmp" "$LEARNINGS_FILE"

RESULT=$($LEARNINGS prune --older-than 30d 2>/dev/null)
assert "$(echo "$RESULT" | jq '.pruned')" "2" "prune removes 2 old learnings"
assert "$(echo "$RESULT" | jq '.remaining')" "5" "prune leaves 5 learnings"
assert "$(jq '.learnings | length' "$LEARNINGS_FILE")" "5" "file has 5 learnings after prune"

# Stats rebuilt after prune
RESULT=$($LEARNINGS stats 2>/dev/null)
assert "$(echo "$RESULT" | jq '.total')" "5" "stats total updated after prune"

# ── Test: recommend with no patterns ───────────────────────
# Clean slate
rm -f "$LEARNINGS_FILE"
RESULT=$($LEARNINGS recommend 2>/dev/null)
assert "$(echo "$RESULT" | jq 'length')" "0" "recommend with no data returns empty array"

# ── Test: recommend detects repeated gate failures ─────────
rm -f "$LEARNINGS_FILE"
for i in 1 2 3 4; do
  $LEARNINGS record --card $((100 + i)) --agent reviewer --type gate-failure \
    --lesson "Gate 4 failed" --tags "persistence" 2>/dev/null >/dev/null
done

RESULT=$($LEARNINGS recommend 2>/dev/null)
assert "$(echo "$RESULT" | jq '[.[] | select(.type == "add-rule")] | length')" "1" \
  "recommend flags repeated gate failures (>3 same tag)"
assert_contains "$(echo "$RESULT" | jq -r '.[0].message')" "persistence" \
  "recommend message mentions the repeated tag"

# ── Test: recommend detects high rework rate ───────────────
rm -f "$LEARNINGS_FILE"
# 3 cards total, 2 with rework → 66%
$LEARNINGS record --card 201 --agent builder --type pattern --lesson "ok" 2>/dev/null >/dev/null
$LEARNINGS record --card 202 --agent reviewer --type rework-cause --lesson "missing tests" 2>/dev/null >/dev/null
$LEARNINGS record --card 203 --agent reviewer --type rework-cause --lesson "missing tests" 2>/dev/null >/dev/null

RESULT=$($LEARNINGS recommend 2>/dev/null)
assert "$(echo "$RESULT" | jq '[.[] | select(.type == "rework-rate")] | length')" "1" \
  "recommend detects high rework rate"

# ── Test: recommend output is valid JSON ───────────────────
RESULT=$($LEARNINGS recommend 2>/dev/null)
if echo "$RESULT" | jq . >/dev/null 2>&1; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); echo "FAIL: recommend output is not valid JSON"
fi

# ── Test: record without optional fields ───────────────────
rm -f "$LEARNINGS_FILE"
RESULT=$($LEARNINGS record --card 300 --agent planner --type pitfall \
  --lesson "Spec missed edge case" 2>/dev/null)
assert "$(jq -r '.learnings[0].context' "$LEARNINGS_FILE")" "null" "context is null when not provided"
assert "$(jq -r '.learnings[0].resolution' "$LEARNINGS_FILE")" "null" "resolution is null when not provided"
assert "$(jq '.learnings[0].tags | length' "$LEARNINGS_FILE")" "0" "tags empty when not provided"

# ── Summary ────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
