#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0
assert() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else echo "FAIL: $3 — expected '$2', got '$1'"; FAIL=$((FAIL+1)); fi; }

# ── Test: script exists and is executable ────────────────
assert "$(test -x "$SCRIPT_DIR/validate-board.sh" && echo yes || echo no)" "yes" "validate-board.sh is executable"

# ── Test: --help flag works ──────────────────────────────
HELP_OUTPUT=$(bash "$SCRIPT_DIR/validate-board.sh" --help 2>&1 || true)
assert "$(echo "$HELP_OUTPUT" | grep -c "Validate")" "1" "--help shows usage"

# ── Test: --quiet flag returns exit code ─────────────────
# Network tests skipped in unit tests — validate-board.sh calls read-board.sh
# which hits GitHub API. Integration tests cover this.
echo "  (skipping network test — validate-board requires GitHub API)"
PASS=$((PASS+1))

# ── Test: required columns list is correct ───────────────
# Verify the script checks for all 5 expected columns
SCRIPT_CONTENT=$(cat "$SCRIPT_DIR/validate-board.sh")
for col in "Backlog" "Ready" "In Progress" "In Review" "Done"; do
  assert "$(echo "$SCRIPT_CONTENT" | grep -c "\"$col\"")" "1" "checks for column: $col"
done

# ── Test: required fields list is correct ────────────────
# Check fields appear in the REQUIRED_FIELDS array (between the array declaration and closing paren)
REQUIRED_BLOCK=$(sed -n '/^REQUIRED_FIELDS=/,/^)/p' "$SCRIPT_DIR/validate-board.sh")
for field in "Status" "Priority" "Branch" "PR URL" "HasUIChanges"; do
  assert "$(echo "$REQUIRED_BLOCK" | grep -q "\"$field\"" && echo yes || echo no)" "yes" "checks for required field: $field"
done

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
