#!/bin/bash
# test-worktree.sh — Tests for worktree.sh argument validation and path resolution.
# Does NOT create actual worktrees — focuses on arg parsing and error paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
WORKTREE_SCRIPT="$SCRIPT_DIR/worktree.sh"

PASS=0; FAIL=0

assert_exit() {
  local expected_exit="$1"
  local description="$2"
  shift 2
  local output
  local actual_exit=0
  output=$("$@" 2>&1) || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $description — expected exit $expected_exit, got $actual_exit"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

assert_output_contains() {
  local needle="$1"
  local description="$2"
  shift 2
  local output
  output=$("$@" 2>&1) || true
  if echo "$output" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $description — output missing '$needle'"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
  fi
}

# ── Test: no command → error ────────────────────────────
assert_exit 1 "no command exits 1" "$WORKTREE_SCRIPT"
assert_output_contains "No command specified" "no command shows usage" "$WORKTREE_SCRIPT"

# ── Test: unknown command → error ───────────────────────
assert_exit 1 "unknown command exits 1" "$WORKTREE_SCRIPT" bogus
assert_output_contains "Unknown command" "unknown command shows error" "$WORKTREE_SCRIPT" bogus

# ── Test: path without --card → error ──────────────────
assert_exit 1 "path without --card exits 1" "$WORKTREE_SCRIPT" path
assert_output_contains "--card" "path without --card mentions --card" "$WORKTREE_SCRIPT" path

# ── Test: cleanup without --card → error ────────────────
assert_exit 1 "cleanup without --card exits 1" "$WORKTREE_SCRIPT" cleanup
assert_output_contains "--card" "cleanup without --card mentions --card" "$WORKTREE_SCRIPT" cleanup

# ── Test: create without --card → error ─────────────────
assert_exit 1 "create without --card exits 1" "$WORKTREE_SCRIPT" create
assert_output_contains "--card" "create without --card mentions --card" "$WORKTREE_SCRIPT" create

# ── Test: create with --card but no --slug → error ──────
assert_exit 1 "create without --slug exits 1" "$WORKTREE_SCRIPT" create --card 999
assert_output_contains "--slug" "create without --slug mentions --slug" "$WORKTREE_SCRIPT" create --card 999

# ── Test: path for non-existent card → exit 1 ──────────
assert_exit 1 "path for non-existent card exits 1" "$WORKTREE_SCRIPT" path --card 99999
assert_output_contains "No worktree found" "path for missing card shows not found" "$WORKTREE_SCRIPT" path --card 99999

# ── Test: list runs without error ───────────────────────
assert_exit 0 "list runs without error" "$WORKTREE_SCRIPT" list

# ── Test: unknown arg → error ───────────────────────────
assert_exit 1 "unknown arg exits 1" "$WORKTREE_SCRIPT" path --card 1 --bogus foo
assert_output_contains "Unknown arg" "unknown arg shows error" "$WORKTREE_SCRIPT" path --card 1 --bogus foo

# ── Test: --help exits 0 ───────────────────────────────
assert_exit 0 "--help exits 0" "$WORKTREE_SCRIPT" --help

# ── Report ──────────────────────────────────────────────
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
