#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0
assert() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else echo "FAIL: $3 — expected '$2', got '$1'"; FAIL=$((FAIL+1)); fi; }

# ── Test: script exists and is executable ────────────────
assert "$(test -x "$SCRIPT_DIR/stitch-api.sh" && echo yes || echo no)" "yes" "stitch-api.sh is executable"

# ── Test: --help flag works ──────────────────────────────
HELP_OUTPUT=$(bash "$SCRIPT_DIR/stitch-api.sh" --help 2>&1 || true)
assert "$(echo "$HELP_OUTPUT" | grep -c "Stitch REST API")" "1" "--help shows usage"

# ── Test: unknown command fails ──────────────────────────
bash "$SCRIPT_DIR/stitch-api.sh" bogus 2>/dev/null && RESULT="ok" || RESULT="fail"
assert "$RESULT" "fail" "unknown command exits non-zero"

# ── Test: generate without --prompt fails ────────────────
bash "$SCRIPT_DIR/stitch-api.sh" generate 2>/dev/null && RESULT="ok" || RESULT="fail"
assert "$RESULT" "fail" "generate without --prompt fails"

# ── Test: apply-design-system without IDs fails ──────────
bash "$SCRIPT_DIR/stitch-api.sh" apply-design-system 2>/dev/null && RESULT="ok" || RESULT="fail"
assert "$RESULT" "fail" "apply-design-system without IDs fails"

# ── Test: apply-design-system with partial IDs fails ─────
bash "$SCRIPT_DIR/stitch-api.sh" apply-design-system --instance-id foo 2>/dev/null && RESULT="ok" || RESULT="fail"
assert "$RESULT" "fail" "apply-design-system with only instance-id fails"

# ── Test: config values loaded ───────────────────────────
assert "$(test -n "$STITCH_PROJECT_ID" && echo set || echo empty)" "set" "STITCH_PROJECT_ID loaded"
assert "$(test -n "$STITCH_DESIGN_SYSTEM_ID" && echo set || echo empty)" "set" "STITCH_DESIGN_SYSTEM_ID loaded"
assert "$(test -n "$GCP_PROJECT" && echo set || echo empty)" "set" "GCP_PROJECT loaded"
assert "$STITCH_MCP_URL" "https://stitch.googleapis.com/mcp" "STITCH_MCP_URL correct"

# ── Test: token cache path ───────────────────────────────
# Token cache should be in /tmp (not persistent)
SCRIPT_CONTENT=$(cat "$SCRIPT_DIR/stitch-api.sh")
assert "$(echo "$SCRIPT_CONTENT" | grep -c 'TOKEN_CACHE="/tmp')" "1" "token cache in /tmp"
assert "$(echo "$SCRIPT_CONTENT" | grep -c 'TOKEN_TTL=3000')" "1" "token TTL is 50 minutes"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
