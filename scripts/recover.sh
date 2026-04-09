#!/bin/bash
# recover.sh — Reconstruct delivery loop state after /tmp wipe or crash.
#
# Usage:
#   ./recover.sh                   # Full recovery (worktrees + state + locks)
#   ./recover.sh --worktrees       # Reconstruct worktrees only
#   ./recover.sh --state           # Clean up state file only
#   ./recover.sh --dry-run         # Show what would be done
#
# Requires: gh, jq, git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
recover.sh — Reconstruct delivery loop state after /tmp wipe or crash.

Recovers:
  1. Worktrees from existing feature branches with open PRs
  2. State file (purge stale entries, rebuild from board)
  3. Simulator lock cleanup
  4. Artifact directories

Usage:
  ./recover.sh                   # Full recovery
  ./recover.sh --worktrees       # Worktrees only
  ./recover.sh --state           # State cleanup only
  ./recover.sh --dry-run         # Preview changes
HELP

MODE="full"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktrees) MODE="worktrees"; shift ;;
    --state)     MODE="state"; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    *)           log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

RECOVERED=0
SKIPPED=0

# ── Step 1: Reconstruct worktrees ─────────────────────────
recover_worktrees() {
  log_info "Recovering worktrees from open PRs..."

  # Ensure base directory exists
  mkdir -p "$WORKTREE_BASE"

  # Find all open PRs targeting autodev
  local prs
  prs=$(gh pr list --repo "$REPO" --base "$BASE_BRANCH" --state open --json number,headRefName,isDraft --jq '.[]' 2>/dev/null) || {
    log_error "Failed to list PRs"
    return 1
  }

  echo "$prs" | while IFS= read -r pr_json; do
    [[ -z "$pr_json" ]] && continue

    local branch pr_num
    branch=$(echo "$pr_json" | jq -r '.headRefName')
    pr_num=$(echo "$pr_json" | jq -r '.number')

    # Extract card ID from branch name (feature/<card-id>-<slug>)
    local card_id
    card_id=$(echo "$branch" | sed -n 's|feature/\([0-9]*\)-.*|\1|p')
    [[ -z "$card_id" ]] && continue

    local wt_path="$WORKTREE_BASE/${branch#feature/}"

    if [[ -d "$wt_path" ]]; then
      log_info "  Worktree exists: $wt_path (PR #$pr_num)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "  [dry-run] Would create: $wt_path from $branch (PR #$pr_num)"
    else
      # Fetch the branch if needed
      git fetch origin "$branch" 2>/dev/null || true

      if git worktree add "$wt_path" "$branch" 2>/dev/null; then
        log_info "  Recovered: $wt_path (PR #$pr_num, card #$card_id)"
        RECOVERED=$((RECOVERED + 1))
      else
        log_warn "  Failed to create worktree for $branch — branch may not exist locally"
        SKIPPED=$((SKIPPED + 1))
      fi
    fi
  done
}

# ── Step 2: Clean up state file ───────────────────────────
recover_state() {
  log_info "Cleaning up state file..."

  if [[ ! -f "$STATE_FILE" ]]; then
    log_info "  No state file found — nothing to clean"
    return
  fi

  # Purge all in-flight entries (they're all stale after a crash)
  local inflight_count
  inflight_count=$(jq '.in_flight // [] | length' "$STATE_FILE" 2>/dev/null || echo 0)

  if [[ "$inflight_count" -gt 0 ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "  [dry-run] Would purge $inflight_count in-flight entries"
    else
      local tmp="${STATE_FILE}.tmp"
      jq '.in_flight = []' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
      log_info "  Purged $inflight_count stale in-flight entries"
      RECOVERED=$((RECOVERED + inflight_count))
    fi
  fi
}

# ── Step 3: Clean up simulator lock ──────────────────────
recover_locks() {
  log_info "Cleaning up locks..."

  if [[ -d "$SIMULATOR_LOCK" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "  [dry-run] Would remove stale simulator lock"
    else
      rm -rf "$SIMULATOR_LOCK"
      log_info "  Removed stale simulator lock"
      RECOVERED=$((RECOVERED + 1))
    fi
  else
    log_info "  No stale locks found"
  fi

  # Kill any orphaned simulators
  xcrun simctl shutdown all 2>/dev/null || true
}

# ── Step 4: Recreate artifact directories ────────────────
recover_artifacts() {
  log_info "Checking artifact directories..."
  mkdir -p "$ARTIFACT_BASE"

  # Create artifact dirs for all open PRs
  local prs
  prs=$(gh pr list --repo "$REPO" --base "$BASE_BRANCH" --state open --json headRefName --jq '.[].headRefName' 2>/dev/null) || return

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    local card_id
    card_id=$(echo "$branch" | sed -n 's|feature/\([0-9]*\)-.*|\1|p')
    [[ -z "$card_id" ]] && continue

    local artifact_dir="$ARTIFACT_BASE/$card_id"
    if [[ ! -d "$artifact_dir" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        log_info "  [dry-run] Would create: $artifact_dir"
      else
        mkdir -p "$artifact_dir"
        log_info "  Created artifact dir: $artifact_dir"
      fi
    fi
  done <<< "$prs"
}

# ── Execute ───────────────────────────────────────────────
case "$MODE" in
  full)
    recover_worktrees
    recover_state
    recover_locks
    recover_artifacts
    ;;
  worktrees)
    recover_worktrees
    ;;
  state)
    recover_state
    recover_locks
    ;;
esac

log_info "Recovery complete: $RECOVERED recovered, $SKIPPED skipped"
