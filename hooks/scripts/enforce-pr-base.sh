#!/bin/bash
# enforce-pr-base.sh — PostToolUse hook for Bash commands.
# After any `gh pr create` command, verify the PR targets autodev (not main).
# Auto-fixes if wrong.

set -euo pipefail

[[ "${ECC_HOOK_PROFILE:-standard}" == "minimal" ]] && exit 0

INPUT=$(cat 2>/dev/null || echo "{}")
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('command',''))" 2>/dev/null || echo "")

[[ -z "$COMMAND" ]] && exit 0

# Only check after gh pr create
if ! echo "$COMMAND" | grep -q 'gh pr create'; then
  exit 0
fi

# Get the stdout from the tool result (contains the PR URL)
STDOUT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stdout',''))" 2>/dev/null || echo "")

# Extract PR number from URL
PR_NUM=$(echo "$STDOUT" | grep -oE 'pull/[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
[[ -z "$PR_NUM" ]] && exit 0

# Check base branch
BASE=$(gh pr view "$PR_NUM" --repo amonick12/helix --json baseRefName --jq '.baseRefName' 2>/dev/null || echo "")

if [[ "$BASE" == "main" ]]; then
  gh pr edit "$PR_NUM" --repo amonick12/helix --base autodev 2>/dev/null
  echo "AUTO-FIXED: PR #$PR_NUM was targeting main, changed to autodev" >&2
fi

exit 0
