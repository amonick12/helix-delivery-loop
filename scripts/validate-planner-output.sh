#!/bin/bash
# validate-planner-output.sh — Verify Planner only wrote tests and spec, not implementation.
# Run after Planner finishes to catch scope violations.
#
# Usage:
#   ./validate-planner-output.sh --worktree <path> [--base autodev]
#
# Exit 0: Planner stayed in scope (only tests + docs)
# Exit 1: Planner modified source files (scope violation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

WORKTREE=""
BASE_BRANCH="autodev"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="$2"; shift 2 ;;
    --base)     BASE_BRANCH="$2"; shift 2 ;;
    *)          echo "Usage: validate-planner-output.sh --worktree <path>" >&2; exit 1 ;;
  esac
done

[[ -z "$WORKTREE" ]] && echo "Error: --worktree required" >&2 && exit 1
[[ ! -d "$WORKTREE" ]] && echo "Error: worktree not found" >&2 && exit 1

cd "$WORKTREE"

# Get all changed files
CHANGED=$(git diff --name-only "origin/${BASE_BRANCH}...HEAD" 2>/dev/null || true)
[[ -z "$CHANGED" ]] && echo "OK: no changes" && exit 0

# Allowed patterns: Tests/, docs/, spec files, criteria files
VIOLATIONS=""
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  case "$file" in
    */Tests/*) ;; # tests are allowed
    docs/*) ;; # docs/specs are allowed
    *.md) ;; # markdown files are allowed
    *.json) ;; # criteria-tests.json etc are allowed
    *)
      VIOLATIONS="${VIOLATIONS}${file}\n"
      ;;
  esac
done <<< "$CHANGED"

if [[ -n "$VIOLATIONS" ]]; then
  echo "VIOLATION: Planner modified source files (Builder's job):" >&2
  echo -e "$VIOLATIONS" | sed 's/^/  /' >&2
  echo "Planner should only write to Tests/ and docs/. Source changes must wait for Builder." >&2
  exit 1
fi

echo "OK: Planner only modified tests and docs"
exit 0
