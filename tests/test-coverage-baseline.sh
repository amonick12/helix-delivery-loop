#!/bin/bash
# test-coverage-baseline.sh — Tests for coverage-baseline.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
CB_SCRIPT="$SCRIPT_DIR/coverage-baseline.sh"

PASS=0; FAIL=0

assert() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $3 — expected '$2', got '$1'"
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

# ── Setup: use temp baselines dir ─────────────────────
TEMP_DIR=$(mktemp -d)
export BASELINES_DIR="$TEMP_DIR"
export BASELINES_FILE="$TEMP_DIR/coverage.json"

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

# ── Test: --help exits 0 ─────────────────────────────
assert_exit 0 "--help exits 0" "$CB_SCRIPT" --help

# ── Test: no command → error ──────────────────────────
assert_exit 1 "no command exits 1" "$CB_SCRIPT"

# ── Test: unknown command → error ─────────────────────
assert_exit 1 "unknown command exits 1" "$CB_SCRIPT" bogus

# ── Test: save missing --branch → error ───────────────
assert_exit 1 "save without --branch exits 1" "$CB_SCRIPT" save --coverage 72

# ── Test: save missing --coverage → error ─────────────
assert_exit 1 "save without --coverage exits 1" "$CB_SCRIPT" save --branch autodev

# ── Test: get missing --branch → error ────────────────
assert_exit 1 "get without --branch exits 1" "$CB_SCRIPT" get

# ── Test: compare missing --current → error ───────────
assert_exit 1 "compare without --current exits 1" "$CB_SCRIPT" compare --branch autodev

# ── Test: compare missing --branch → error ────────────
assert_exit 1 "compare without --branch exits 1" "$CB_SCRIPT" compare --current 70

# ── Test: save + get roundtrip ────────────────────────
OUTPUT=$("$CB_SCRIPT" save --branch autodev --coverage 72.5 2>/dev/null)
assert_json "$OUTPUT" '.saved' "true" "save returns saved=true"
assert_json "$OUTPUT" '.branch' "autodev" "save returns branch"
assert_json "$OUTPUT" '.coverage' "72.5" "save returns coverage"

GET_OUTPUT=$("$CB_SCRIPT" get --branch autodev 2>/dev/null)
assert "$GET_OUTPUT" "72.5" "get returns saved value"

# ── Test: get for unknown branch falls back to autodev ─
FALLBACK=$("$CB_SCRIPT" get --branch "feature/42-test" 2>/dev/null)
assert "$FALLBACK" "72.5" "get falls back to autodev baseline"

# ── Test: get for unknown branch with no autodev → null
EMPTY_DIR=$(mktemp -d)
NULL_OUTPUT=$(BASELINES_DIR="$EMPTY_DIR" BASELINES_FILE="$EMPTY_DIR/coverage.json" "$CB_SCRIPT" get --branch "feature/99-new" 2>/dev/null)
assert "$NULL_OUTPUT" "null" "get returns null when no baseline exists"
rm -rf "$EMPTY_DIR"

# ── Test: compare — no baseline → passes ──────────────
EMPTY_DIR2=$(mktemp -d)
CMP_NONE=$(BASELINES_DIR="$EMPTY_DIR2" BASELINES_FILE="$EMPTY_DIR2/coverage.json" "$CB_SCRIPT" compare --current 65 --branch autodev 2>/dev/null)
assert_json "$CMP_NONE" '.passed' "true" "compare passes when no baseline"
assert_json "$CMP_NONE" '.current' "65" "compare returns current"
assert_json "$CMP_NONE" '.baseline' "null" "compare returns null baseline"
rm -rf "$EMPTY_DIR2"

# ── Test: compare — equal to baseline → passes ───────
CMP_OK=$("$CB_SCRIPT" compare --current 72.5 --branch autodev 2>/dev/null)
assert_json "$CMP_OK" '.passed' "true" "compare passes when equal to baseline"
assert_json "$CMP_OK" '.baseline' "72.5" "compare returns baseline"

# ── Test: compare — any drop → fails (tolerance=0) ───
CMP_DROP=$("$CB_SCRIPT" compare --current 72.0 --branch autodev 2>/dev/null)
assert_json "$CMP_DROP" '.passed' "false" "compare fails on any drop (72.0 vs 72.5, tolerance=0)"

# ── Test: compare — below baseline → fails ───────────
CMP_FAIL=$("$CB_SCRIPT" compare --current 71.0 --branch autodev 2>/dev/null)
assert_json "$CMP_FAIL" '.passed' "false" "compare fails when below baseline (71.0 vs 72.5)"
assert_json "$CMP_FAIL" '.delta' "-1.5" "compare returns correct delta"

# ── Test: compare — improvement → passes ──────────────
CMP_UP=$("$CB_SCRIPT" compare --current 80.0 --branch autodev 2>/dev/null)
assert_json "$CMP_UP" '.passed' "true" "compare passes when coverage improved"
assert_json "$CMP_UP" '.delta' "7.5" "compare returns positive delta"

# ── Test: save overwrites previous value ──────────────
"$CB_SCRIPT" save --branch autodev --coverage 75.0 2>/dev/null > /dev/null
GET_UPDATED=$("$CB_SCRIPT" get --branch autodev 2>/dev/null)
assert "$GET_UPDATED" "75.0" "save overwrites previous baseline"

# ── Test: multiple branches coexist ───────────────────
"$CB_SCRIPT" save --branch "feature/42-voice" --coverage 76.2 2>/dev/null > /dev/null
GET_FEATURE=$("$CB_SCRIPT" get --branch "feature/42-voice" 2>/dev/null)
assert "$GET_FEATURE" "76.2" "feature branch has own baseline"
GET_AUTODEV=$("$CB_SCRIPT" get --branch autodev 2>/dev/null)
assert "$GET_AUTODEV" "75.0" "autodev baseline unchanged after feature save"

# ── Test: storage file has updated timestamp ──────────
HAS_UPDATED=$(jq 'has("updated")' "$BASELINES_FILE")
assert "$HAS_UPDATED" "true" "baselines file has updated timestamp"

# ── Test: custom COVERAGE_DROP_TOLERANCE ──────────────
# Set tolerance to 2%, so 72.5 vs 75.0 baseline = -2.5% → fail
CMP_CUSTOM_FAIL=$(COVERAGE_DROP_TOLERANCE=2 "$CB_SCRIPT" compare --current 72.5 --branch autodev 2>/dev/null)
assert_json "$CMP_CUSTOM_FAIL" '.passed' "false" "custom tolerance 2%: 72.5 vs 75.0 = -2.5 fails"

# Set tolerance to 3%, so 72.5 vs 75.0 = -2.5% → passes
CMP_CUSTOM_OK=$(COVERAGE_DROP_TOLERANCE=3 "$CB_SCRIPT" compare --current 72.5 --branch autodev 2>/dev/null)
assert_json "$CMP_CUSTOM_OK" '.passed' "true" "custom tolerance 3%: 72.5 vs 75.0 = -2.5 passes"

# ── Report ────────────────────────────────────────────
echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
