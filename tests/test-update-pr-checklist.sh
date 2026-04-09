#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
source "$SCRIPT_DIR/config.sh"

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
  if echo "$1" | grep -qF -- "$2"; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $3 — expected to contain '$2'"
    echo "  Got: $1"
    FAIL=$((FAIL+1))
  fi
}

UPDATE_SCRIPT="$SCRIPT_DIR/update-pr-checklist.sh"

# ── Test 1: Missing --pr argument ──────────────────────
echo "Test 1: Missing --pr argument"
OUTPUT=$(DRY_RUN=1 bash "$UPDATE_SCRIPT" --card 137 2>&1 || true)
assert_contains "$OUTPUT" "--pr" "should error about missing --pr"

# ── Test 2: Missing --card argument ────────────────────
echo "Test 2: Missing --card argument"
OUTPUT=$(DRY_RUN=1 bash "$UPDATE_SCRIPT" --pr 42 2>&1 || true)
assert_contains "$OUTPUT" "--card" "should error about missing --card"

# ── Test 3: Initialize empty PR with acceptance criteria ─
echo "Test 3: Initialize PR with acceptance criteria from issue"
MOCK_ISSUE_BODY="## Acceptance Criteria
- [ ] Add journal entry detail view
- [ ] Support dark mode
- [ ] Handle empty state"
export MOCK_ISSUE_BODY
MOCK_PR_BODY="Closes #137"
export MOCK_PR_BODY

OUTPUT=$(DRY_RUN=1 bash "$UPDATE_SCRIPT" --pr 42 --card 137 2>/dev/null)
ALL_CHECKED=$(echo "$OUTPUT" | jq -r '.all_checked')
TOTAL=$(echo "$OUTPUT" | jq -r '.total')
CHECKED=$(echo "$OUTPUT" | jq -r '.checked')

assert "$ALL_CHECKED" "false" "all_checked should be false when nothing checked"
# 3 acceptance criteria + 14 quality gates = 17 total
assert "$TOTAL" "17" "total should be 17 (3 criteria + 14 gates)"
assert "$CHECKED" "0" "checked should be 0"

# ── Test 4: Check off a specific criterion ─────────────
echo "Test 4: Check off a specific acceptance criterion"
MOCK_PR_BODY="Closes #137

## Acceptance Criteria
- [ ] Add journal entry detail view
- [ ] Support dark mode
- [ ] Handle empty state

## Quality Gates
- [ ] Build passes
- [ ] Unit tests pass
- [ ] Package tests pass
- [ ] Code review: 0 P0/P1
- [ ] Coverage above baseline
- [ ] Performance check pass (if UI)
- [ ] XCUITests pass (if UI)
- [ ] Screen recordings posted (if UI)
- [ ] Before/after screenshots (if UI)
- [ ] Design fidelity verified (if UI)
- [ ] Visual QA pass (if UI)"
export MOCK_PR_BODY
# Empty issue body since PR already has the section
MOCK_ISSUE_BODY=""
export MOCK_ISSUE_BODY

OUTPUT=$(DRY_RUN=1 bash "$UPDATE_SCRIPT" --pr 42 --card 137 --check "Support dark mode" 2>/dev/null)
CHECKED=$(echo "$OUTPUT" | jq -r '.checked')
TOTAL=$(echo "$OUTPUT" | jq -r '.total')
ALL_CHECKED=$(echo "$OUTPUT" | jq -r '.all_checked')

assert "$CHECKED" "1" "checked should be 1 after checking one criterion"
assert "$TOTAL" "14" "total should remain 14"
assert "$ALL_CHECKED" "false" "all_checked should still be false"

# Verify the unchecked list doesn't contain the checked criterion
UNCHECKED=$(echo "$OUTPUT" | jq -r '.unchecked | join(",")')
assert_contains "$UNCHECKED" "Add journal entry detail view" "unchecked should contain remaining criteria"
if echo "$UNCHECKED" | grep -qF "Support dark mode"; then
  echo "FAIL: unchecked should NOT contain 'Support dark mode' — got: $UNCHECKED"
  FAIL=$((FAIL+1))
else
  PASS=$((PASS+1))
fi

# ── Test 5: Check off a quality gate ───────────────────
echo "Test 5: Check off a quality gate"
OUTPUT=$(DRY_RUN=1 bash "$UPDATE_SCRIPT" --pr 42 --card 137 --check-gate "Build passes" 2>/dev/null)
CHECKED=$(echo "$OUTPUT" | jq -r '.checked')
assert "$CHECKED" "1" "checked should be 1 after checking one gate"

# ── Test 6: All checked detection ──────────────────────
echo "Test 6: All checked detection"
MOCK_PR_BODY="## Acceptance Criteria
- [x] Add journal entry detail view
- [x] Support dark mode

## Quality Gates
- [x] Build passes
- [x] Unit tests pass
- [x] Package tests pass
- [x] Code review: 0 P0/P1
- [x] Coverage above baseline
- [x] Performance check pass (if UI)
- [x] XCUITests pass (if UI)
- [x] Screen recordings posted (if UI)
- [x] Before/after screenshots (if UI)
- [x] Design fidelity verified (if UI)
- [x] Visual QA pass (if UI)"
export MOCK_PR_BODY
MOCK_ISSUE_BODY=""
export MOCK_ISSUE_BODY

OUTPUT=$(DRY_RUN=1 bash "$UPDATE_SCRIPT" --pr 42 --card 137 2>/dev/null)
ALL_CHECKED=$(echo "$OUTPUT" | jq -r '.all_checked')
TOTAL=$(echo "$OUTPUT" | jq -r '.total')
CHECKED=$(echo "$OUTPUT" | jq -r '.checked')
UNCHECKED_COUNT=$(echo "$OUTPUT" | jq -r '.unchecked | length')

assert "$ALL_CHECKED" "true" "all_checked should be true when everything checked"
assert "$TOTAL" "13" "total should be 13 (2 criteria + 11 gates)"
assert "$CHECKED" "13" "checked should be 13"
assert "$UNCHECKED_COUNT" "0" "unchecked should be empty"

# ── Test 7: Quality gates added when missing ───────────
echo "Test 7: Quality gates section auto-added"
MOCK_PR_BODY="Some PR body without gates"
export MOCK_PR_BODY
MOCK_ISSUE_BODY=""
export MOCK_ISSUE_BODY

OUTPUT=$(DRY_RUN=1 bash "$UPDATE_SCRIPT" --pr 42 --card 137 2>/dev/null)
TOTAL=$(echo "$OUTPUT" | jq -r '.total')
# Should have 14 quality gate checkboxes
assert "$TOTAL" "14" "should have 14 quality gate checkboxes when no acceptance criteria"

# ── Test 8: Mixed checked/unchecked ────────────────────
echo "Test 8: Mixed checked and unchecked items"
MOCK_PR_BODY="## Acceptance Criteria
- [x] First criterion
- [ ] Second criterion

## Quality Gates
- [x] Build passes
- [x] Unit tests pass
- [ ] Package tests pass
- [ ] Code review: 0 P0/P1
- [ ] Coverage above baseline
- [ ] Performance check pass (if UI)
- [ ] XCUITests pass (if UI)
- [ ] Screen recordings posted (if UI)
- [ ] Before/after screenshots (if UI)
- [ ] Design fidelity verified (if UI)
- [ ] Visual QA pass (if UI)"
export MOCK_PR_BODY
MOCK_ISSUE_BODY=""
export MOCK_ISSUE_BODY

OUTPUT=$(DRY_RUN=1 bash "$UPDATE_SCRIPT" --pr 42 --card 137 2>/dev/null)
ALL_CHECKED=$(echo "$OUTPUT" | jq -r '.all_checked')
TOTAL=$(echo "$OUTPUT" | jq -r '.total')
CHECKED=$(echo "$OUTPUT" | jq -r '.checked')
UNCHECKED_COUNT=$(echo "$OUTPUT" | jq -r '.unchecked | length')

assert "$ALL_CHECKED" "false" "all_checked should be false with mixed items"
assert "$TOTAL" "13" "total should be 13"
assert "$CHECKED" "3" "checked should be 3 (1 criterion + 2 gates)"
assert "$UNCHECKED_COUNT" "10" "unchecked should have 10 items"

# ── Test 9: JSON output is valid ──────────────────────
echo "Test 9: JSON output validity"
MOCK_PR_BODY=""
export MOCK_PR_BODY
MOCK_ISSUE_BODY=""
export MOCK_ISSUE_BODY

OUTPUT=$(DRY_RUN=1 bash "$UPDATE_SCRIPT" --pr 42 --card 137 2>/dev/null)
echo "$OUTPUT" | jq . > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
  PASS=$((PASS+1))
else
  echo "FAIL: output is not valid JSON"
  FAIL=$((FAIL+1))
fi

# Verify all expected keys exist
for key in all_checked total checked unchecked; do
  if echo "$OUTPUT" | jq "has(\"$key\")" 2>/dev/null | grep -q "true"; then
    PASS=$((PASS+1))
  else
    echo "FAIL: missing key '$key' in JSON output"
    FAIL=$((FAIL+1))
  fi
done

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
