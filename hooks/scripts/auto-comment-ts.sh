#!/bin/bash
# PostToolUse hook: auto-update comment timestamp after posting PR/issue comments
# Prevents dispatcher from re-triggering on agent-posted comments

if echo "$CLAUDE_TOOL_INPUT" | grep -qE 'gh (pr|issue) comment|gh api.*comments.*POST'; then
  SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
  card=$(echo "$CLAUDE_TOOL_INPUT" | grep -oE '\-\-card [0-9]+|card [0-9]+|/issues/[0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -n "$card" ] && [ -f "$SCRIPTS/update-comment-ts.sh" ]; then
    bash "$SCRIPTS/update-comment-ts.sh" --card "$card" 2>/dev/null
  fi
fi
