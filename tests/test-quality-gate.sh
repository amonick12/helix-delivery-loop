#!/bin/bash
# test-quality-gate.sh — Tests for quality-gate.sh orchestration logic.
# Uses DRY_RUN=1 throughout — does NOT run actual builds or tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
QG_SCRIPT="$SCRIPT_DIR/quality-gate.sh"

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

MOCK_WORKTREE="/tmp/helix-qg-test-worktree"

# ── Test: missing --card → error ───────────────────────
assert_exit 1 "missing --card exits 1" env DRY_RUN=1 "$QG_SCRIPT" --worktree "$MOCK_WORKTREE"

# ── Test: missing --worktree → error ──────────────────
assert_exit 1 "missing --worktree exits 1" env DRY_RUN=1 "$QG_SCRIPT" --card 137

# ── Test: invalid gate number → error ─────────────────
assert_exit 1 "gate 0 exits 1" env DRY_RUN=1 "$QG_SCRIPT" --card 137 --worktree "$MOCK_WORKTREE" --gate 0
assert_exit 1 "gate 16 exits 1" env DRY_RUN=1 "$QG_SCRIPT" --card 137 --worktree "$MOCK_WORKTREE" --gate 16

# ── Test: --help exits 0 ──────────────────────────────
assert_exit 0 "--help exits 0" "$QG_SCRIPT" --help

# ── Test: full run with DRY_RUN=1 (all gates pass) ────
OUTPUT=$(DRY_RUN=1 HAS_UI_CHANGES=Yes DESIGN_URL="https://example.com/design" "$QG_SCRIPT" --card 137 --worktree "$MOCK_WORKTREE" 2>/dev/null)

assert_json "$OUTPUT" '.card' "137" "card number in output"
assert_json "$OUTPUT" '.passed' "true" "all gates passed in dry run"
assert_json "$OUTPUT" '.first_failure' "null" "no failures in dry run"
assert_json "$OUTPUT" '.self_healable' "true" "self_healable true when all pass"
assert_json "$OUTPUT" '.gates | length' "15" "all 15 gates ran"

# ── Test: gates run in order (1 through 15) ──────────
for i in $(seq 1 15); do
  actual_gate=$(echo "$OUTPUT" | jq ".gates[$((i-1))].gate")
  assert "$actual_gate" "$i" "gate $i is at position $((i-1))"
done

# ── Test: gate names are correct ─────────────────────
assert_json "$OUTPUT" '.gates[0].name' "Build" "gate 1 name"
assert_json "$OUTPUT" '.gates[1].name' "Unit Tests" "gate 2 name"
assert_json "$OUTPUT" '.gates[2].name' "Package Tests" "gate 3 name"
assert_json "$OUTPUT" '.gates[3].name' "Code Review" "gate 4 name"
assert_json "$OUTPUT" '.gates[4].name' "Code Coverage" "gate 5 name"
assert_json "$OUTPUT" '.gates[5].name' "Memory Leak Detection" "gate 6 name"
assert_json "$OUTPUT" '.gates[6].name' "Data Migration Safety" "gate 7 name"
assert_json "$OUTPUT" '.gates[7].name' "Localization Check" "gate 8 name"
assert_json "$OUTPUT" '.gates[8].name' "Accessibility Audit" "gate 9 name"
assert_json "$OUTPUT" '.gates[9].name' "Write XCUITests" "gate 10 name"
assert_json "$OUTPUT" '.gates[10].name' "Run XCUITests + Record" "gate 11 name"
assert_json "$OUTPUT" '.gates[11].name' "Visual Evidence" "gate 12 name"
assert_json "$OUTPUT" '.gates[12].name' "Design Fidelity" "gate 13 name"
assert_json "$OUTPUT" '.gates[13].name' "Visual QA" "gate 14 name"
assert_json "$OUTPUT" '.gates[14].name' "TestFlight Build" "gate 15 name"

# ── Test: gates skip correctly when HAS_UI_CHANGES=No ─
OUTPUT_NO_UI=$(DRY_RUN=1 HAS_UI_CHANGES=No "$QG_SCRIPT" --card 200 --worktree "$MOCK_WORKTREE" 2>/dev/null)

assert_json "$OUTPUT_NO_UI" '.passed' "true" "all pass with no UI changes"
assert_json "$OUTPUT_NO_UI" '.gates | length' "15" "still 15 gate entries"

# Gates 1-9 should NOT be skipped (build, tests, coverage, memory, migration, l10n, a11y always run)
for i in 0 1 2 3 4 5 6 7 8; do
  actual=$(echo "$OUTPUT_NO_UI" | jq ".gates[$i].skipped // false")
  assert "$actual" "false" "gate $((i+1)) not skipped when no UI changes"
done

# Gate 10 (Write XCUITests) should be skipped when no UI changes
actual=$(echo "$OUTPUT_NO_UI" | jq ".gates[9].skipped // false")
assert "$actual" "true" "gate 10 skipped when no UI changes"

# Gates 11-15 should be skipped when no UI changes (regression runs at merge, not per-PR)
for i in 10 11 12 13 14; do
  actual=$(echo "$OUTPUT_NO_UI" | jq ".gates[$i].skipped // false")
  assert "$actual" "true" "gate $((i+1)) skipped when no UI changes"
done

# ── Test: gate 13 skips when no DesignURL ────────────
OUTPUT_NO_DESIGN=$(DRY_RUN=1 HAS_UI_CHANGES=Yes DESIGN_URL="" "$QG_SCRIPT" --card 300 --worktree "$MOCK_WORKTREE" 2>/dev/null)

assert_json "$OUTPUT_NO_DESIGN" '.gates[12].skipped' "true" "gate 13 skipped without DesignURL"
# Gate 14 should NOT be skipped (has UI changes, no DesignURL requirement)
assert_json "$OUTPUT_NO_DESIGN" '.gates[13].skipped // false' "false" "gate 14 not skipped with UI changes"

# ── Test: single gate mode (--gate N) ─────────────────
SINGLE_OUTPUT=$(DRY_RUN=1 HAS_UI_CHANGES=Yes "$QG_SCRIPT" --card 137 --worktree "$MOCK_WORKTREE" --gate 3 2>/dev/null)

assert_json "$SINGLE_OUTPUT" '.gates | length' "1" "single gate mode returns 1 gate"
assert_json "$SINGLE_OUTPUT" '.gates[0].gate' "3" "single gate runs gate 3"
assert_json "$SINGLE_OUTPUT" '.gates[0].name' "Package Tests" "single gate 3 name"
assert_json "$SINGLE_OUTPUT" '.card' "137" "card number in single gate output"

# ── Test: single gate mode with skippable gate ────────
SKIP_SINGLE=$(DRY_RUN=1 HAS_UI_CHANGES=No "$QG_SCRIPT" --card 137 --worktree "$MOCK_WORKTREE" --gate 11 2>/dev/null)

assert_json "$SKIP_SINGLE" '.gates | length' "1" "single gate 11 returns 1 entry"
# Gate 11 now skips when no UI (regression moved to Releaser post-merge)
assert_json "$SKIP_SINGLE" '.gates[0].skipped' "true" "gate 11 skipped with no UI changes"

# ── Test: output JSON format is valid ─────────────────
# Check that all required top-level keys exist
for key in card passed gates first_failure self_healable; do
  has_key=$(echo "$OUTPUT" | jq "has(\"$key\")")
  assert "$has_key" "true" "output has key '$key'"
done

# Check gate object has required fields
for field in gate name passed; do
  has_field=$(echo "$OUTPUT" | jq ".gates[0] | has(\"$field\")")
  assert "$has_field" "true" "gate object has field '$field'"
done

# ── Test: DRY_RUN gates include expected detail fields ─
assert_json "$OUTPUT" '.gates[0] | has("duration_sec")' "true" "build gate has duration_sec"
assert_json "$OUTPUT" '.gates[1] | has("tests")' "true" "unit tests gate has tests count"
assert_json "$OUTPUT" '.gates[3] | has("llm_gate")' "true" "code review gate has llm_gate marker"

# ── Test: new gates (6-8) have expected DRY_RUN fields ─
assert_json "$OUTPUT" '.gates[5].name' "Memory Leak Detection" "gate 6 name is Memory Leak Detection"
assert_json "$OUTPUT" '.gates[5] | has("leaks_found")' "true" "memory leak gate has leaks_found"
assert_json "$OUTPUT" '.gates[5].leaks_found' "0" "memory leak gate shows 0 leaks in dry run"

assert_json "$OUTPUT" '.gates[6].name' "Data Migration Safety" "gate 7 name is Data Migration Safety"
assert_json "$OUTPUT" '.gates[6] | has("model_changes")' "true" "data migration gate has model_changes"
assert_json "$OUTPUT" '.gates[6].model_changes' "false" "data migration gate shows no model changes in dry run"

assert_json "$OUTPUT" '.gates[7].name' "Localization Check" "gate 8 name is Localization Check"
assert_json "$OUTPUT" '.gates[7] | has("hardcoded_strings")' "true" "localization gate has hardcoded_strings"
assert_json "$OUTPUT" '.gates[7].hardcoded_strings' "0" "localization gate shows 0 hardcoded strings in dry run"

# ── Test: Accessibility Audit gate (9) has expected fields ─
assert_json "$OUTPUT" '.gates[8] | has("llm_gate")' "true" "a11y gate has llm_gate marker"
assert_json "$OUTPUT" '.gates[8].name' "Accessibility Audit" "a11y gate name correct"

# ── Test: Visual Evidence gate (12) has expected DRY_RUN fields ─
assert_json "$OUTPUT" '.gates[11].name' "Visual Evidence" "gate 12 name is Visual Evidence"
assert_json "$OUTPUT" '.gates[11] | has("recordings_found")' "true" "visual evidence gate has recordings_found"
assert_json "$OUTPUT" '.gates[11] | has("screenshots_found")' "true" "visual evidence gate has screenshots_found"

# ── Test: Design Fidelity gate (13) has structured fidelity_checks ─
OUTPUT_WITH_DESIGN=$(DRY_RUN=1 HAS_UI_CHANGES=Yes DESIGN_URL="https://example.com/design" "$QG_SCRIPT" --card 137 --worktree "$MOCK_WORKTREE" --gate 13 2>/dev/null)
assert_json "$OUTPUT_WITH_DESIGN" '.gates[0] | has("fidelity_checks")' "true" "design fidelity gate has fidelity_checks"
assert_json "$OUTPUT_WITH_DESIGN" '.gates[0].fidelity_checks.overall_passed' "true" "fidelity_checks overall_passed is true in dry run"
assert_json "$OUTPUT_WITH_DESIGN" '.gates[0].fidelity_checks.checks | length' "5" "fidelity_checks has 5 criteria"

# ── Report ─────────────────────────────────────────────
echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
