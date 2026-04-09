#!/bin/bash
# enforce-simulator.sh — PreToolUse hook for Bash commands.
# Blocks xcodebuild/simctl commands that target wrong simulator devices.
# This runs BEFORE every Bash tool call — the agent cannot bypass it.

set -euo pipefail

# Skip if hooks minimized
[[ "${ECC_HOOK_PROFILE:-standard}" == "minimal" ]] && exit 0

# Read the command from stdin (PreToolUse hook receives tool input as JSON on stdin)
INPUT=$(cat 2>/dev/null || echo "{}")
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('command',''))" 2>/dev/null || echo "")

[[ -z "$COMMAND" ]] && exit 0

# Block: Tester/Reviewer running unit test scripts (only Builder should)
# These are full test sweeps that waste time and aren't the agent's job.
if echo "$COMMAND" | grep -qE 'run-all-package-unit-tests\.sh|run-unit-tests\.sh|run-tests\.sh'; then
  # Check if a Tester or Reviewer is in-flight (they shouldn't run unit tests)
  STATE_FILE="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo ".")}/.claude/delivery-loop-state.json"
  if [[ -f "$STATE_FILE" ]]; then
    INFLIGHT_AGENTS=$(jq -r '[.in_flight // [] | .[].agent] | join(",")' "$STATE_FILE" 2>/dev/null || echo "")
    if echo "$INFLIGHT_AGENTS" | grep -qE 'tester|reviewer'; then
      echo "BLOCKED: Tester/Reviewer must not run unit test scripts. Only Builder runs unit tests." >&2
      exit 2
    fi
  fi
fi

# Only check simulator commands below
if ! echo "$COMMAND" | grep -qE 'xcodebuild|simctl|xcrun.*simctl'; then
  exit 0
fi

# Dynamically resolve the expected UDID from the only iPhone 17 Pro (Codex) device
EXPECTED_UDID=$(xcrun simctl list devices available 2>/dev/null | grep 'iPhone 17 Pro (Codex)' | grep -oE '[A-F0-9-]{36}' | head -1)
[[ -z "$EXPECTED_UDID" ]] && exit 0  # no device found, skip enforcement

# Block: simctl create (never create new devices)
if echo "$COMMAND" | grep -q 'simctl create'; then
  echo "BLOCKED: Do not create simulator devices. Use the existing iPhone 17 Pro (Codex): $EXPECTED_UDID" >&2
  exit 2
fi

# Block: xcodebuild with a destination ID that isn't our device
if echo "$COMMAND" | grep -qE 'destination.*id=' ; then
  USED_UDID=$(echo "$COMMAND" | grep -oE 'id=[A-F0-9-]{36}' | head -1 | cut -d= -f2)
  if [[ -n "$USED_UDID" && "$USED_UDID" != "$EXPECTED_UDID" ]]; then
    echo "BLOCKED: Wrong simulator UDID '$USED_UDID'. Must use $EXPECTED_UDID (iPhone 17 Pro Codex)" >&2
    exit 2
  fi
fi

# Block: simctl boot with wrong UDID
if echo "$COMMAND" | grep -q 'simctl boot'; then
  BOOT_UDID=$(echo "$COMMAND" | grep -oE '[A-F0-9-]{36}' | head -1)
  if [[ -n "$BOOT_UDID" && "$BOOT_UDID" != "$EXPECTED_UDID" ]]; then
    echo "BLOCKED: Booting wrong simulator '$BOOT_UDID'. Must use $EXPECTED_UDID" >&2
    exit 2
  fi
fi

# Block: xcodebuild test without -only-testing (full suite runs)
if echo "$COMMAND" | grep -qE 'xcodebuild\s+test' && ! echo "$COMMAND" | grep -q 'only-testing' && ! echo "$COMMAND" | grep -q 'build-for-testing'; then
  echo "BLOCKED: xcodebuild test without -only-testing flag. Use resolve-uitests.sh to get test targets." >&2
  exit 2
fi

# Block: committing build artifacts (DerivedData, build/, .build/)
if echo "$COMMAND" | grep -qE 'git (add|commit)' && echo "$COMMAND" | grep -qE 'build/|DerivedData|\.build/'; then
  echo "BLOCKED: Do not commit build artifacts (build/, DerivedData/, .build/)" >&2
  exit 2
fi

exit 0
