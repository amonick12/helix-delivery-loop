#!/bin/bash
# validate-simulator.sh — Validate simulator state before any agent uses it.
# Enforces: only iPhone 17 Pro (Codex), only one device, correct UDID.
#
# Usage:
#   ./validate-simulator.sh
#
# Exit 0: outputs the valid UDID to stdout
# Exit 1: prints error to stderr
#
# This script MUST be called before any xcodebuild test or simctl command.

set -euo pipefail

EXPECTED_NAME="iPhone 17 Pro (Codex)"

# 1. Find the device
EXPECTED_UDID=$(xcrun simctl list devices available 2>/dev/null | grep "$EXPECTED_NAME" | grep -oE '[A-F0-9-]{36}' | head -1 || true)

if [[ -z "$EXPECTED_UDID" ]]; then
  echo "FAIL: '$EXPECTED_NAME' simulator not found. Do NOT create one — ask the user." >&2
  exit 1
fi

# 2. Count how many matching devices exist (should be exactly 1)
DEVICE_COUNT=$(xcrun simctl list devices available 2>/dev/null | grep -c "$EXPECTED_NAME" || true)
DEVICE_COUNT=$(echo "$DEVICE_COUNT" | tr -d '[:space:]')
if [[ "$DEVICE_COUNT" -gt 1 ]]; then
  echo "FAIL: Found $DEVICE_COUNT '$EXPECTED_NAME' devices. Should be exactly 1." >&2
  exit 1
fi

# 3. Check no OTHER simulators are booted (ours can be booted or not)
BOOTED_LINES=$(xcrun simctl list devices booted 2>/dev/null | grep "Booted" || true)
BOOTED_COUNT=$(echo "$BOOTED_LINES" | grep -c "Booted" 2>/dev/null || true)
BOOTED_COUNT=$(echo "$BOOTED_COUNT" | tr -d '[:space:]')

if [[ "$BOOTED_COUNT" -gt 1 ]]; then
  echo "FAIL: $BOOTED_COUNT simulators booted. Only one allowed." >&2
  exit 1
fi

if [[ "$BOOTED_COUNT" -eq 1 ]]; then
  BOOTED_UDID=$(echo "$BOOTED_LINES" | grep -oE '[A-F0-9-]{36}' | head -1 || true)
  if [[ -n "$BOOTED_UDID" && "$BOOTED_UDID" != "$EXPECTED_UDID" ]]; then
    echo "FAIL: Wrong simulator booted ($BOOTED_UDID). Expected $EXPECTED_UDID." >&2
    exit 1
  fi
fi

# 4. Output validated UDID
echo "$EXPECTED_UDID"
