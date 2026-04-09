#!/bin/bash
# check-conflicts.sh — Detect potential merge conflicts with other open PRs.
#
# Usage:
#   ./check-conflicts.sh --card 137 --branch feature/137-slug
#
# Output: JSON { "conflicts_likely": true/false, "overlapping_files": [...], "conflicting_prs": [...] }
#
# Env:
#   DRY_RUN=1   Skip gh calls, use mock data

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
check-conflicts.sh — Detect potential merge conflicts with other open PRs.

Usage:
  ./check-conflicts.sh --card 137 --branch feature/137-slug

Options:
  --card <N>          Issue number (required)
  --branch <name>     Branch name (required)

Output: JSON { "conflicts_likely": true/false, "overlapping_files": [...], "conflicting_prs": [...] }

Env:
  DRY_RUN=1   Skip gh calls, use mock data
HELP

# ── Parse args ─────────────────────────────────────────
CARD=""
BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)     CARD="$2"; shift 2 ;;
    --branch)   BRANCH="$2"; shift 2 ;;
    *)          log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$CARD" ]]; then
  log_error "--card <number> is required"
  exit 1
fi
if [[ -z "$BRANCH" ]]; then
  log_error "--branch <name> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Get files changed in this branch ─────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  OUR_FILES="${MOCK_OUR_FILES:-src/FileA.swift
src/FileB.swift}"
else
  OUR_FILES=$(git diff --name-only "origin/$BASE_BRANCH...$BRANCH" 2>/dev/null || echo "")
fi

if [[ -z "$OUR_FILES" ]]; then
  jq -n '{conflicts_likely: false, overlapping_files: [], conflicting_prs: []}'
  exit 0
fi

# ── Get all open PR branches ─────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  OTHER_BRANCHES="${MOCK_OTHER_BRANCHES:-}"
else
  OTHER_BRANCHES=$(gh pr list --base "$BASE_BRANCH" --state open --json headRefName,number --repo "$REPO" 2>/dev/null | \
    jq -r ".[] | select(.headRefName != \"$BRANCH\") | \"\(.number):\(.headRefName)\"" 2>/dev/null || echo "")
fi

if [[ -z "$OTHER_BRANCHES" ]]; then
  jq -n '{conflicts_likely: false, overlapping_files: [], conflicting_prs: []}'
  exit 0
fi

# ── Compare file lists ───────────────────────────────
OVERLAPPING_FILES="[]"
CONFLICTING_PRS="[]"
CONFLICTS_LIKELY=false

while IFS=: read -r pr_num other_branch; do
  [[ -z "$other_branch" ]] && continue

  if [[ "$DRY_RUN" == "1" ]]; then
    OTHER_FILES="${MOCK_OTHER_FILES:-}"
  else
    OTHER_FILES=$(git diff --name-only "origin/$BASE_BRANCH...$other_branch" 2>/dev/null || echo "")
  fi

  [[ -z "$OTHER_FILES" ]] && continue

  # Find common files
  COMMON=$(comm -12 <(echo "$OUR_FILES" | sort) <(echo "$OTHER_FILES" | sort) 2>/dev/null || true)

  if [[ -n "$COMMON" ]]; then
    CONFLICTS_LIKELY=true
    while IFS= read -r file; do
      OVERLAPPING_FILES=$(echo "$OVERLAPPING_FILES" | jq --arg f "$file" '. + [$f] | unique')
    done <<< "$COMMON"
    CONFLICTING_PRS=$(echo "$CONFLICTING_PRS" | jq --argjson n "$pr_num" --arg b "$other_branch" '. + [{"pr": $n, "branch": $b}]')
  fi
done <<< "$OTHER_BRANCHES"

# ── Output JSON ──────────────────────────────────────
jq -n \
  --argjson conflicts_likely "$CONFLICTS_LIKELY" \
  --argjson overlapping_files "$OVERLAPPING_FILES" \
  --argjson conflicting_prs "$CONFLICTING_PRS" \
  '{conflicts_likely: $conflicts_likely, overlapping_files: $overlapping_files, conflicting_prs: $conflicting_prs}'
