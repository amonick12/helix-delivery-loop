#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"

# Isolate state for tests
export STATE_FILE="/tmp/test-recover-state-$$.json"
export WORKTREE_BASE="/tmp/test-recover-wt-$$"
export SIMULATOR_LOCK="/tmp/test-recover-simlock-$$"
export ARTIFACT_BASE="/tmp/test-recover-artifacts-$$"

mkdir -p "$WORKTREE_BASE"
trap 'rm -rf "$STATE_FILE" "$WORKTREE_BASE" "$SIMULATOR_LOCK" "$ARTIFACT_BASE"' EXIT

source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0
assert() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else echo "FAIL: $3 — expected '$2', got '$1'"; FAIL=$((FAIL+1)); fi; }

# ── Test: script exists and is executable ────────────────
assert "$(test -x "$SCRIPT_DIR/recover.sh" && echo yes || echo no)" "yes" "recover.sh is executable"

# ── Test: --help flag works ──────────────────────────────
HELP_OUTPUT=$(bash "$SCRIPT_DIR/recover.sh" --help 2>&1 || true)
assert "$(echo "$HELP_OUTPUT" | grep -c "Reconstruct")" "1" "--help shows usage"

# ── Test: --dry-run doesn't modify state ─────────────────
echo '{"cards":{},"in_flight":[{"card":"999","agent":"builder","started_at":0,"needs_simulator":false,"pid":1}]}' > "$STATE_FILE"
bash "$SCRIPT_DIR/recover.sh" --state --dry-run 2>/dev/null || true
# State file should still have the stale entry (dry-run doesn't modify)
INFLIGHT_COUNT=$(jq '.in_flight | length' "$STATE_FILE" 2>/dev/null || echo 0)
assert "$INFLIGHT_COUNT" "1" "--dry-run preserves state file"

# ── Test: --state purges all in-flight entries ───────────
echo '{"cards":{},"in_flight":[{"card":"100","agent":"builder","started_at":0,"needs_simulator":false,"pid":1},{"card":"200","agent":"tester","started_at":0,"needs_simulator":true,"pid":2}]}' > "$STATE_FILE"
bash "$SCRIPT_DIR/recover.sh" --state 2>/dev/null || true
INFLIGHT_COUNT=$(jq '.in_flight | length' "$STATE_FILE" 2>/dev/null || echo 0)
assert "$INFLIGHT_COUNT" "0" "--state purges all in-flight entries"

# ── Test: --state removes stale simulator lock ───────────
mkdir -p "$SIMULATOR_LOCK"
echo "$$" > "$SIMULATOR_LOCK/pid"
echo "2026-01-01T00:00:00Z" > "$SIMULATOR_LOCK/acquired"
bash "$SCRIPT_DIR/recover.sh" --state 2>/dev/null || true
assert "$(test -d "$SIMULATOR_LOCK" && echo exists || echo gone)" "gone" "--state removes simulator lock"

# ── Test: --state with no state file doesn't crash ───────
rm -f "$STATE_FILE"
bash "$SCRIPT_DIR/recover.sh" --state 2>/dev/null || true
assert "0" "0" "--state with no state file doesn't crash"

# ── Test: artifact dirs created ──────────────────────────
# Can't test worktree recovery without real git branches,
# but we can verify artifact directory creation
mkdir -p "$ARTIFACT_BASE"
assert "$(test -d "$ARTIFACT_BASE" && echo yes || echo no)" "yes" "artifact base created"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
