#!/bin/bash
# resolve-uitests.sh — Deterministically resolve which UITest classes to run for a card.
# Only returns test classes that were ADDED or MODIFIED on this branch.
# Agents MUST use this output — never choose test targets manually.
#
# Usage:
#   ./resolve-uitests.sh --worktree <path> [--base autodev]
#
# Output: newline-separated list of -only-testing targets, e.g.:
#   helix-appUITests/OnboardingProgressIndicatorUITests
#   helix-appUITests/OnboardingPrivacyUITests
#
# If no UITest files changed, outputs nothing (exit 0).
# If UITest files changed but can't determine class name, outputs the file path as a warning.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

WORKTREE=""
BASE_BRANCH="autodev"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="$2"; shift 2 ;;
    --base)     BASE_BRANCH="$2"; shift 2 ;;
    -h|--help)  echo "Usage: resolve-uitests.sh --worktree <path> [--base autodev]"; exit 0 ;;
    *)          echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$WORKTREE" ]] && echo "Error: --worktree required" >&2 && exit 1
[[ ! -d "$WORKTREE" ]] && echo "Error: worktree not found: $WORKTREE" >&2 && exit 1

cd "$WORKTREE"

# Get UITest files that were added or modified on this branch
UITEST_FILES=$(git diff --name-only --diff-filter=AM "origin/${BASE_BRANCH}...HEAD" -- 'helix-appUITests/*.swift' 2>/dev/null || true)

[[ -z "$UITEST_FILES" ]] && exit 0

# Extract class names from each file
while IFS= read -r file; do
  [[ -z "$file" || ! -f "$file" ]] && continue

  # Extract test class names (must end with "Tests" to skip base classes/helpers)
  CLASS_NAME=$(grep -E '^(final )?class [A-Za-z0-9_]*Tests\s*:' "$file" 2>/dev/null \
    | head -1 \
    | sed -E 's/^(final )?class ([A-Za-z0-9_]+).*/\2/' || true)

  # Skip non-test files (base classes, helpers)
  [[ -z "$CLASS_NAME" ]] && continue

  echo "helix-appUITests/${CLASS_NAME}"
done <<< "$UITEST_FILES"
