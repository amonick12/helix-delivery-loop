#!/bin/bash
# PreToolUse hook: kill stale xcodebuild before starting a new one
# Prevents parallel builds that fight over the simulator

if echo "$CLAUDE_TOOL_INPUT" | grep -qE 'xcodebuild.*(test|build|archive)'; then
  pkill -f xcodebuild 2>/dev/null || true
fi
