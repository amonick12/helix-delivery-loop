#!/bin/bash
# PreToolUse hook: block force-push to autodev (the base branch)
# A force-push to autodev would overwrite all unmerged work

cmd=$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.command // ""' 2>/dev/null)

if [[ $? -ne 0 ]]; then
  echo "[helix] ERROR: Could not parse CLAUDE_TOOL_INPUT — blocking as precaution" >&2
  exit 2
fi

if [[ -z "$cmd" ]]; then
  exit 0
fi

# Match: git push --force / -f / --force-with-lease targeting autodev
if echo "$cmd" | grep -qE 'git push.*(--force|-f\b|--force-with-lease)' && \
   echo "$cmd" | grep -qE 'autodev'; then
  echo "[helix] BLOCKED: Force-push to autodev is not allowed. Use git push without --force. If a rebase is needed, use rebase-open-prs.sh instead." >&2
  exit 2
fi

exit 0
