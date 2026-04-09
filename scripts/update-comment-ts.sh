#!/bin/bash
# update-comment-ts.sh — Update last_comment_check timestamp for a card.
#
# Usage:
#   ./update-comment-ts.sh --card 137
#
# Updates STATE_FILE so the dispatcher does not re-trigger on the agent's own comments.
#
# Env:
#   DRY_RUN=1   Print what would happen without writing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
update-comment-ts.sh — Update last_comment_check timestamp for a card.

Usage:
  ./update-comment-ts.sh --card 137

Options:
  --card <N>   Issue number (required)

Updates cards[N].last_comment_check to current ISO timestamp in the state file.
Uses atomic write (temp file + mv) for safety.

Env:
  DRY_RUN=1   Print what would happen without writing
HELP

# ── Parse args ─────────────────────────────────────────
CARD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card) CARD="$2"; shift 2 ;;
    *)      log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$CARD" ]]; then
  log_error "--card <number> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Ensure state file exists ──────────────────────────
if [[ ! -f "$STATE_FILE" ]]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  echo '{"cards":{}}' > "$STATE_FILE"
fi

# ── Generate timestamp ────────────────────────────────
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# ── Update state file atomically ──────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  log_info "[DRY_RUN] Would set cards[$CARD].last_comment_check=$TIMESTAMP in $STATE_FILE"
  exit 0
fi

TEMP_FILE=$(mktemp "${STATE_FILE}.XXXXXX")

jq --arg card "$CARD" --arg ts "$TIMESTAMP" '
  .cards[$card] = (.cards[$card] // {}) |
  .cards[$card].last_comment_check = $ts
' "$STATE_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$STATE_FILE"

log_info "Updated last_comment_check for card #$CARD to $TIMESTAMP"
