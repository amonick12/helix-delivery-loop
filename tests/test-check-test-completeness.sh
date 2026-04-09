#!/bin/bash
# test-check-test-completeness.sh — Tests for check-test-completeness.sh
# Uses DRY_RUN=1 throughout — does NOT invoke LLM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
TC_SCRIPT="$SCRIPT_DIR/check-test-completeness.sh"

PASS=0; FAIL=0

assert() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $3 — expected '$2', got '$1'"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local expected_exit="$1"
  local description="$2"
  shift 2
  local output actual_exit=0
  output=$("$@" 2>&1) || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $description — expected exit $expected_exit, got $actual_exit"
    echo "  output: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_json() {
  local json="$1" jq_expr="$2" expected="$3" description="$4"
  local actual
  actual=$(echo "$json" | jq -r "$jq_expr" 2>/dev/null || echo "JQ_ERROR")
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $description — expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

MOCK_WORKTREE="/tmp/helix-tc-test-worktree"

# ── Test: missing --card → error ──────────────────────
assert_exit 1 "missing --card exits 1" env DRY_RUN=1 "$TC_SCRIPT" --worktree "$MOCK_WORKTREE" --issue-body "test"

# ── Test: missing --worktree → error ─────────────────
assert_exit 1 "missing --worktree exits 1" env DRY_RUN=1 "$TC_SCRIPT" --card 137 --issue-body "test"

# ── Test: missing --issue-body → error ───────────────
assert_exit 1 "missing --issue-body exits 1" env DRY_RUN=1 "$TC_SCRIPT" --card 137 --worktree "$MOCK_WORKTREE"

# ── Test: --help exits 0 ─────────────────────────────
assert_exit 0 "--help exits 0" "$TC_SCRIPT" --help

# ── Test: DRY_RUN with criteria returns complete ─────
ISSUE_BODY="## Acceptance Criteria
- [ ] User can create a new entry
- [ ] Entry is saved to SwiftData
- [x] Confirmation toast appears"

OUTPUT=$(DRY_RUN=1 "$TC_SCRIPT" --card 137 --worktree "$MOCK_WORKTREE" --issue-body "$ISSUE_BODY" 2>/dev/null)

assert_json "$OUTPUT" '.complete' "true" "DRY_RUN returns complete=true"
assert_json "$OUTPUT" '.card' "137" "card number in output"
assert_json "$OUTPUT" '.criteria | length' "3" "3 criteria extracted"
assert_json "$OUTPUT" '.criteria[0].has_test' "true" "DRY_RUN mock: first criterion has_test"
assert_json "$OUTPUT" '.criteria[0].criterion' "User can create a new entry" "first criterion text"
assert_json "$OUTPUT" '.criteria[1].criterion' "Entry is saved to SwiftData" "second criterion text"
assert_json "$OUTPUT" '.criteria[2].criterion' "Confirmation toast appears" "third criterion text (from [x] item)"

# ── Test: DRY_RUN with no criteria returns empty ─────
NO_CRITERIA_BODY="This issue has no checklist items, just free text."

OUTPUT_EMPTY=$(DRY_RUN=1 "$TC_SCRIPT" --card 200 --worktree "$MOCK_WORKTREE" --issue-body "$NO_CRITERIA_BODY" 2>/dev/null)

assert_json "$OUTPUT_EMPTY" '.complete' "true" "no criteria = complete (nothing to check)"
assert_json "$OUTPUT_EMPTY" '.criteria | length' "0" "0 criteria when no checklist items"
assert_json "$OUTPUT_EMPTY" '.card' "200" "card number with no criteria"

# ── Test: issue body from file ───────────────────────
BODY_FILE="/tmp/helix-tc-test-body.md"
cat > "$BODY_FILE" <<'BODY'
## Acceptance Criteria
- [ ] Dark mode toggle works
- [ ] Settings persist across app restart
BODY

OUTPUT_FILE=$(DRY_RUN=1 "$TC_SCRIPT" --card 50 --worktree "$MOCK_WORKTREE" --issue-body "@$BODY_FILE" 2>/dev/null)

assert_json "$OUTPUT_FILE" '.complete' "true" "file-based body: complete"
assert_json "$OUTPUT_FILE" '.criteria | length' "2" "file-based body: 2 criteria"
assert_json "$OUTPUT_FILE" '.criteria[0].criterion' "Dark mode toggle works" "file-based: first criterion"
rm -f "$BODY_FILE"

# ── Test: @nonexistent file → error ──────────────────
assert_exit 1 "nonexistent body file exits 1" env DRY_RUN=1 "$TC_SCRIPT" --card 137 --worktree "$MOCK_WORKTREE" --issue-body "@/tmp/helix-tc-nonexistent-file.md"

# ── Test: non-DRY_RUN with no test files → incomplete ─
# Create a mock worktree with empty Packages dir
LIVE_WORKTREE="/tmp/helix-tc-live-test"
rm -rf "$LIVE_WORKTREE"
mkdir -p "$LIVE_WORKTREE/Packages"

LIVE_BODY="- [ ] Feature X works
- [ ] Feature Y works"

OUTPUT_LIVE=$(DRY_RUN=0 "$TC_SCRIPT" --card 300 --worktree "$LIVE_WORKTREE" --issue-body "$LIVE_BODY" 2>/dev/null)

assert_json "$OUTPUT_LIVE" '.complete' "false" "no test files = incomplete"
assert_json "$OUTPUT_LIVE" '.criteria | length' "2" "2 criteria found"
assert_json "$OUTPUT_LIVE" '.criteria[0].has_test' "false" "no tests = has_test false"
assert_json "$OUTPUT_LIVE" '.criteria[0].test_file' "null" "no tests = test_file null"

rm -rf "$LIVE_WORKTREE"

# ── Test: non-DRY_RUN with test files → LLM prompt ──
LLM_WORKTREE="/tmp/helix-tc-llm-test"
rm -rf "$LLM_WORKTREE"
mkdir -p "$LLM_WORKTREE/Packages/FeatureJournal/Tests/FeatureJournalTests"
cat > "$LLM_WORKTREE/Packages/FeatureJournal/Tests/FeatureJournalTests/CreateEntryTests.swift" <<'SWIFT'
import Testing
@Test func testCreateEntry() {
    // test creating a journal entry
}
SWIFT

LLM_BODY="- [ ] User can create a journal entry"

OUTPUT_LLM=$(DRY_RUN=0 "$TC_SCRIPT" --card 400 --worktree "$LLM_WORKTREE" --issue-body "$LLM_BODY" 2>/dev/null)

assert_json "$OUTPUT_LLM" '.card' "400" "LLM mode: card number"
assert_json "$OUTPUT_LLM" '.llm_gate' "true" "LLM mode: llm_gate flag"
assert_json "$OUTPUT_LLM" '.criteria_count' "1" "LLM mode: criteria count"
assert_json "$OUTPUT_LLM" '.test_file_count' "1" "LLM mode: test file count"
# Prompt should contain the criterion and test content
HAS_CRITERION=$(echo "$OUTPUT_LLM" | jq -r '.prompt' | grep -c "User can create a journal entry" || true)
assert "$HAS_CRITERION" "1" "LLM prompt contains criterion"
HAS_TEST_CONTENT=$(echo "$OUTPUT_LLM" | jq -r '.prompt' | grep -c "testCreateEntry" || true)
assert "$HAS_TEST_CONTENT" "1" "LLM prompt contains test content"

rm -rf "$LLM_WORKTREE"

# ── Test: asterisk-style checklist items ─────────────
STAR_BODY="* [ ] Star-style criterion A
* [x] Star-style criterion B"

OUTPUT_STAR=$(DRY_RUN=1 "$TC_SCRIPT" --card 500 --worktree "$MOCK_WORKTREE" --issue-body "$STAR_BODY" 2>/dev/null)

assert_json "$OUTPUT_STAR" '.criteria | length' "2" "asterisk-style checklist items found"
assert_json "$OUTPUT_STAR" '.criteria[0].criterion' "Star-style criterion A" "asterisk: first criterion"

# ── Report ────────────────────────────────────────────
echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
