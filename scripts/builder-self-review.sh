#!/bin/bash
# builder-self-review.sh — Scan diff for CLAUDE.md violations before commit.
#
# Checks changed files for common patterns that violate project rules.
# Run this before committing to catch issues early.
#
# Usage:
#   ./builder-self-review.sh --worktree <path>
#
# Output: JSON { violations[], clean }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
builder-self-review.sh — Scan diff for CLAUDE.md violations.

Usage:
  ./builder-self-review.sh --worktree <path>

Checks: try? on save, DispatchQueue, hardcoded fonts, missing accessibilityLabel,
        XCTestCase in new tests, missing do/catch on persistence.
HELP

WORKTREE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="$2"; shift 2 ;;
    *)          log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$WORKTREE" || ! -d "$WORKTREE" ]] && log_error "--worktree required (valid directory)" && exit 1

cd "$WORKTREE"

# Get the diff of changed lines (additions only)
DIFF=$(git diff "origin/$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null || echo "")
ADDED_LINES=$(echo "$DIFF" | grep '^+' | grep -v '^+++' || true)

# Get changed file list
CHANGED_FILES=$(git diff --name-only "origin/$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null || echo "")

VIOLATIONS=()

# ── Check 1: try? on modelContext.save() ─────────────────
SAVE_VIOLATIONS=$(echo "$ADDED_LINES" | grep -n 'try?.*modelContext\.save\|try?.*\.save()' 2>/dev/null || true)
if [[ -n "$SAVE_VIOLATIONS" ]]; then
  VIOLATIONS+=("{\"rule\": \"do_catch_on_save\", \"severity\": \"P1\", \"description\": \"try? on modelContext.save() — use do/catch per CLAUDE.md\", \"count\": $(echo "$SAVE_VIOLATIONS" | wc -l | tr -d ' ')}")
fi

# ── Check 2: DispatchQueue usage ─────────────────────────
GCD_VIOLATIONS=$(echo "$ADDED_LINES" | grep -n 'DispatchQueue\.' 2>/dev/null || true)
if [[ -n "$GCD_VIOLATIONS" ]]; then
  VIOLATIONS+=("{\"rule\": \"no_gcd\", \"severity\": \"P1\", \"description\": \"DispatchQueue usage — use Task { @MainActor in } per CLAUDE.md\", \"count\": $(echo "$GCD_VIOLATIONS" | wc -l | tr -d ' ')}")
fi

# ── Check 3: Hardcoded fonts ────────────────────────────
FONT_VIOLATIONS=$(echo "$ADDED_LINES" | grep -n '\.font(\.' | grep -v 'helixFont\|// font ok' 2>/dev/null || true)
if [[ -n "$FONT_VIOLATIONS" ]]; then
  VIOLATIONS+=("{\"rule\": \"no_hardcoded_font\", \"severity\": \"P1\", \"description\": \"Hardcoded .font() — use helixFont per CLAUDE.md\", \"count\": $(echo "$FONT_VIOLATIONS" | wc -l | tr -d ' ')}")
fi

# ── Check 4: XCTestCase in new test files ────────────────
NEW_TEST_FILES=$(echo "$CHANGED_FILES" | grep 'Tests/' || true)
if [[ -n "$NEW_TEST_FILES" ]]; then
  XCTEST_VIOLATIONS=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # Only check files that are new (not in base branch)
    if ! git show "origin/$BASE_BRANCH:$f" >/dev/null 2>&1; then
      if grep -q 'import XCTest\|XCTestCase' "$f" 2>/dev/null; then
        XCTEST_VIOLATIONS="${XCTEST_VIOLATIONS}${f}\n"
      fi
    fi
  done <<< "$NEW_TEST_FILES"
  if [[ -n "$XCTEST_VIOLATIONS" ]]; then
    COUNT=$(echo -e "$XCTEST_VIOLATIONS" | grep -c '.' || echo 0)
    VIOLATIONS+=("{\"rule\": \"swift_testing_standard\", \"severity\": \"P1\", \"description\": \"New test files use XCTestCase — use import Testing per CLAUDE.md\", \"count\": $COUNT}")
  fi
fi

# ── Check 5: Missing accessibilityLabel on interactive elements ──
# Check for Button/NavigationLink/Toggle without accessibilityLabel nearby
A11Y_VIOLATIONS=$(echo "$ADDED_LINES" | grep -c 'Button\|NavigationLink\|Toggle(' 2>/dev/null || echo 0)
A11Y_LABELS=$(echo "$ADDED_LINES" | grep -c 'accessibilityLabel\|accessibilityIdentifier' 2>/dev/null || echo 0)
if [[ "$A11Y_VIOLATIONS" -gt 0 && "$A11Y_LABELS" -eq 0 ]]; then
  VIOLATIONS+=("{\"rule\": \"accessibility_label_required\", \"severity\": \"P2\", \"description\": \"Interactive elements added but no accessibilityLabel found in diff\", \"count\": $A11Y_VIOLATIONS}")
fi

# ── Determine result ─────────────────────────────────────
VIOLATION_COUNT=${#VIOLATIONS[@]}
CLEAN=true
[[ "$VIOLATION_COUNT" -gt 0 ]] && CLEAN=false

# ── Output JSON ──────────────────────────────────────────
if [[ "$VIOLATION_COUNT" -eq 0 ]]; then
  echo '{"violations": [], "clean": true}'
else
  VIOLATIONS_JSON=$(printf '%s\n' "${VIOLATIONS[@]}" | jq -s '.')
  jq -n --argjson violations "$VIOLATIONS_JSON" --argjson clean "$CLEAN" \
    '{violations: $violations, clean: $clean}'
fi
