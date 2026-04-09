#!/bin/bash
# session-cleanup.sh — Stop hook: clean up in-flight registry and stale state on session end.
# Runs automatically when Claude Code stops (Stop hook).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/../../scripts" && pwd)"

# Skip if hooks are disabled
[[ "${ECC_HOOK_PROFILE:-standard}" == "minimal" ]] && exit 0

# 1. Clear all in-flight entries (session is ending, agents are dead)
STATE_FILE="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo ".")}/.claude/delivery-loop-state.json"
if [[ -f "$STATE_FILE" ]]; then
  IN_FLIGHT=$(jq '.in_flight // [] | length' "$STATE_FILE" 2>/dev/null || echo 0)
  if [[ "$IN_FLIGHT" -gt 0 ]]; then
    TMP="${STATE_FILE}.tmp"
    jq '.in_flight = []' "$STATE_FILE" > "$TMP" && mv "$TMP" "$STATE_FILE"
    echo "[cleanup] Cleared $IN_FLIGHT stale in-flight entries"
  fi
fi

# 2. Release simulator lock if held
rm -f /tmp/helix-simulator.lock 2>/dev/null || true

# 3. Kill any lingering xcodebuild processes from agents
pkill -f "xcodebuild.*helix-wt" 2>/dev/null || true

# 4. Shutdown simulator if booted by an agent
xcrun simctl shutdown all 2>/dev/null || true

echo "[cleanup] Session cleanup complete"
