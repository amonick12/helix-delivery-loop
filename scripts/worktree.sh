#!/bin/bash
# worktree.sh — Git worktree lifecycle management for delivery loop cards.
#
# Usage:
#   ./worktree.sh create --card 137 --slug cognitive-action-lifecycle
#   ./worktree.sh path --card 137
#   ./worktree.sh cleanup --card 137
#   ./worktree.sh cleanup-stale
#   ./worktree.sh list
#
# Commands:
#   create        Create a worktree for a card (branch: feature/<card>-<slug>)
#   path          Print the worktree path for a card (exit 1 if not found)
#   cleanup       Remove worktree and delete local branch for a card
#   cleanup-stale Remove worktrees for Done cards older than 24h
#   list          List all active worktrees with card numbers and branches
#
# Requires: git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
worktree.sh — Git worktree lifecycle management for delivery loop cards.

Usage:
  ./worktree.sh create --card 137 --slug cognitive-action-lifecycle
  ./worktree.sh path --card 137
  ./worktree.sh cleanup --card 137
  ./worktree.sh cleanup-stale
  ./worktree.sh list

Commands:
  create        Create a worktree for a card (branch: feature/<card>-<slug>)
  path          Print the worktree path for a card (exit 1 if not found)
  cleanup       Remove worktree and delete local branch for a card
  cleanup-stale Remove worktrees for Done cards older than 24h
  list          List all active worktrees with card numbers and branches
HELP

# ── Subcommand dispatch ─────────────────────────────────
COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
  log_error "No command specified. Use: create | path | cleanup | cleanup-stale | list"
  exit 1
fi
shift

# ── Parse args ──────────────────────────────────────────
CARD=""
SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card) CARD="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    *)      log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────
require_card() {
  if [[ -z "$CARD" ]]; then
    log_error "--card <number> is required"
    exit 1
  fi
}

find_worktree_path() {
  local card="$1"
  local match
  match=$(find "$WORKTREE_BASE" -maxdepth 1 -type d -name "${card}-*" 2>/dev/null | head -1)
  echo "$match"
}

# ── Commands ────────────────────────────────────────────
cmd_create() {
  require_card
  if [[ -z "$SLUG" ]]; then
    log_error "--slug <name> is required for create"
    exit 1
  fi

  local wt_path="$WORKTREE_BASE/$CARD-$SLUG"
  local branch="feature/$CARD-$SLUG"

  if [[ -d "$wt_path" ]]; then
    log_warn "Worktree already exists: $wt_path"
    echo "$wt_path"
    return 0
  fi

  # Ensure base directory exists
  mkdir -p "$WORKTREE_BASE"

  # Fetch latest from origin
  git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true

  git worktree add "$wt_path" -b "$branch" "origin/$BASE_BRANCH"
  log_info "Created worktree: $wt_path (branch: $branch)"
  echo "$wt_path"
}

cmd_path() {
  require_card
  local wt_path
  wt_path=$(find_worktree_path "$CARD")

  if [[ -z "$wt_path" ]]; then
    log_error "No worktree found for card $CARD"
    exit 1
  fi

  echo "$wt_path"
}

cmd_cleanup() {
  require_card
  local wt_path
  wt_path=$(find_worktree_path "$CARD")

  if [[ -z "$wt_path" ]]; then
    log_warn "No worktree found for card $CARD — nothing to clean up"
    return 0
  fi

  local dir_name
  dir_name=$(basename "$wt_path")
  local branch="feature/$dir_name"

  git worktree remove "$wt_path" --force 2>/dev/null || {
    log_warn "worktree remove failed, removing directory manually"
    rm -rf "$wt_path"
    git worktree prune
  }

  git branch -D "$branch" 2>/dev/null || log_warn "Branch $branch not found or already deleted"

  log_info "Cleaned up worktree for card $CARD: $wt_path (branch: $branch)"
}

cmd_cleanup_stale() {
  # Read board to find Done cards
  local board_json
  board_json=$("$SCRIPT_DIR/read-board.sh" --column "Done" 2>/dev/null) || {
    log_error "Failed to read board"
    exit 1
  }

  local done_cards
  done_cards=$(echo "$board_json" | jq -r '.cards[].issue_number // empty')

  if [[ -z "$done_cards" ]]; then
    log_info "No Done cards found"
    return 0
  fi

  local now
  now=$(date +%s)
  local stale_threshold=$((24 * 60 * 60))
  local cleaned=0

  while IFS= read -r card_num; do
    [[ -z "$card_num" ]] && continue

    local wt_path
    wt_path=$(find_worktree_path "$card_num")
    [[ -z "$wt_path" ]] && continue

    # Check directory age (modification time)
    local dir_mtime
    dir_mtime=$(stat -f %m "$wt_path" 2>/dev/null || echo 0)
    local age=$((now - dir_mtime))

    if [[ $age -gt $stale_threshold ]]; then
      log_info "Stale worktree for Done card #$card_num (age: $((age / 3600))h) — cleaning up"
      CARD="$card_num" cmd_cleanup
      cleaned=$((cleaned + 1))
    fi
  done <<< "$done_cards"

  log_info "Cleaned up $cleaned stale worktree(s)"
}

cmd_list() {
  # List worktrees filtered to WORKTREE_BASE paths
  git worktree list 2>/dev/null | while IFS= read -r line; do
    if [[ "$line" == *"$WORKTREE_BASE"* ]]; then
      local wt_dir
      wt_dir=$(echo "$line" | awk '{print $1}')
      local dir_name
      dir_name=$(basename "$wt_dir")
      local card_num
      card_num=$(echo "$dir_name" | grep -oE '^[0-9]+' || echo "?")
      local branch
      branch=$(echo "$line" | grep -oE '\[.*\]' || echo "[unknown]")
      echo "Card #$card_num  $wt_dir  $branch"
    fi
  done
}

# ── Dispatch ────────────────────────────────────────────
case "$COMMAND" in
  create)        cmd_create ;;
  path)          cmd_path ;;
  cleanup)       cmd_cleanup ;;
  cleanup-stale) cmd_cleanup_stale ;;
  list)          cmd_list ;;
  *)
    log_error "Unknown command: $COMMAND"
    log_error "Valid commands: create | path | cleanup | cleanup-stale | list"
    exit 1
    ;;
esac
