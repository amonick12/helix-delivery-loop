#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0
assert() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else echo "FAIL: $3 — expected '$2', got '$1'"; FAIL=$((FAIL+1)); fi; }

# ── Test: gh_retry function exists ───────────────────────
type gh_retry &>/dev/null && RESULT="yes" || RESULT="no"
assert "$RESULT" "yes" "gh_retry function is defined"

# ── Test: gh_retry passes through successful command ─────
OUTPUT=$(gh_retry echo "hello world" 2>/dev/null)
assert "$OUTPUT" "hello world" "gh_retry passes through success"

# ── Test: gh_retry returns exit code on non-retryable failure ──
gh_retry false 2>/dev/null && RESULT="ok" || RESULT="fail"
assert "$RESULT" "fail" "gh_retry returns failure for non-retryable error"

# ── Test: gh_retry passes through exit code ──────────────
set +e
gh_retry bash -c "exit 42" 2>/dev/null
EXIT_CODE=$?
set -e
assert "$EXIT_CODE" "42" "gh_retry preserves exit code"

# ── Test: gh_retry handles command with arguments ────────
OUTPUT=$(gh_retry echo "-n" "test" 2>/dev/null)
assert "$OUTPUT" "test" "gh_retry handles multi-arg command"

# ── Test: gh_retry handles command with pipes in args ────
OUTPUT=$(gh_retry bash -c 'echo "pipe test"' 2>/dev/null)
assert "$OUTPUT" "pipe test" "gh_retry handles bash -c subcommand"

# ── Test: implementation has correct retry count ─────────
SCRIPT_CONTENT=$(cat "$SCRIPT_DIR/config.sh")
assert "$(echo "$SCRIPT_CONTENT" | grep -c 'max_attempts=3')" "1" "max_attempts is 3"
assert "$(echo "$SCRIPT_CONTENT" | grep -c 'backoff=2')" "1" "initial backoff is 2s"

# ── Test: retries on rate limit keywords ─────────────────
# Verify the retry logic checks for rate limit strings in the grep pattern
GH_RETRY_FUNC=$(sed -n '/^gh_retry()/,/^}/p' "$SCRIPT_DIR/config.sh")
assert "$(echo "$GH_RETRY_FUNC" | grep -q 'rate limit' && echo yes || echo no)" "yes" "checks for 'rate limit' in error"
assert "$(echo "$GH_RETRY_FUNC" | grep -q '429' && echo yes || echo no)" "yes" "checks for HTTP 429"
assert "$(echo "$GH_RETRY_FUNC" | grep -q '403' && echo yes || echo no)" "yes" "checks for HTTP 403"
assert "$(echo "$GH_RETRY_FUNC" | grep -q 'connection refused' && echo yes || echo no)" "yes" "checks for connection refused"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
