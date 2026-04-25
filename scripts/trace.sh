#!/bin/bash
# trace.sh — print a card's full timeline across the delivery loop.
#
# Stitches together:
#   - dispatch-log entries (every dispatch decision)
#   - postagent runs (cleanup outcomes, dead-letter events)
#   - state.sh fields (last_agent, retry counts, timer)
#   - GitHub events on the issue (labels, comments)
#   - PR events if a PR exists (commits, approvals, merge)
#   - email-queue files referencing this card
#
# Usage:
#   ./trace.sh --card <N>
#   ./trace.sh --card <N> --json    # machine-readable
#
# This is the single command to answer "why is card #N where it is and how
# did it get there." Use it when status.sh shows a card stuck and you don't
# know which agent or signal is at fault.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
trace.sh — full timeline for a card.

Usage:
  ./trace.sh --card <N>
  ./trace.sh --card <N> --json

Pulls dispatch log, state, GitHub issue/PR events, and email queue files into
one chronological view.
HELP

CARD=""
JSON_OUT="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --card) CARD="$2"; shift 2 ;;
    --json) JSON_OUT="true"; shift ;;
    *)      log_error "Unknown arg: $1"; exit 1 ;;
  esac
done
[[ -z "$CARD" ]] && { log_error "--card required"; exit 1; }

# ── Dispatch log entries for this card ──────────────────
DISPATCH_LOG="$HELIX_REPO_ROOT/.claude/plugins/helix-delivery-loop/logs/dispatch-log.jsonl"
DISPATCH_EVENTS=$(
  if [[ -f "$DISPATCH_LOG" ]]; then
    grep "\"card\":$CARD\\b\|\"card\":\"$CARD\"" "$DISPATCH_LOG" 2>/dev/null \
      | jq -c '{ts:(.ts // .timestamp // .created_at // "unknown"), source:"dispatch", agent, outcome, error, reason}' \
      || true
  fi
)

# ── State for this card ─────────────────────────────────
STATE=$(jq --arg c "$CARD" '.cards[$c] // {}' "$STATE_FILE" 2>/dev/null || echo "{}")

# ── GitHub events ───────────────────────────────────────
ISSUE_EVENTS=""
if [[ "${DRY_RUN:-0}" != "1" ]]; then
  ISSUE_EVENTS=$(gh api "repos/${REPO}/issues/${CARD}/events" 2>/dev/null \
    | jq -c '.[] | {ts:.created_at, source:"github", actor:(.actor.login // "system"), event:.event, label:(.label.name // null)}' \
    || true)
fi

# ── PR events (if a PR exists) ──────────────────────────
PR_EVENTS=""
PR_NUM=""
if [[ "${DRY_RUN:-0}" != "1" ]]; then
  PR_NUM=$(gh pr list --repo "$REPO" --state all --search "linked:issue-$CARD" \
    --json number --limit 1 --jq '.[0].number // empty' 2>/dev/null || true)
  if [[ -n "$PR_NUM" ]]; then
    PR_EVENTS=$(gh api "repos/${REPO}/issues/${PR_NUM}/events" 2>/dev/null \
      | jq -c --arg pr "$PR_NUM" '.[] | {ts:.created_at, source:("pr#"+$pr), actor:(.actor.login // "system"), event:.event, label:(.label.name // null)}' \
      || true)
    PR_REVIEWS=$(gh api "repos/${REPO}/pulls/${PR_NUM}/reviews" 2>/dev/null \
      | jq -c --arg pr "$PR_NUM" '.[] | {ts:.submitted_at, source:("pr#"+$pr), actor:(.user.login // "system"), event:("review_"+ (.state | ascii_downcase))}' \
      || true)
    PR_EVENTS="$PR_EVENTS"$'\n'"$PR_REVIEWS"
  fi
fi

# ── Email queue files referencing this card ────────────
QUEUE_DIR="${EPIC_EMAIL_QUEUE_DIR:-/tmp/helix-epic-emails-pending}"
EMAIL_EVENTS=""
if [[ -d "$QUEUE_DIR" ]]; then
  for f in "$QUEUE_DIR"/design-${CARD}.json "$QUEUE_DIR"/epic-${CARD}.json "$QUEUE_DIR"/dead-letter-${CARD}.json; do
    [[ -f "$f" ]] || continue
    line=$(jq -c --arg f "$(basename "$f")" '{ts:.created_at, source:"email", kind:.kind, subject:.subject, sent:.sent, file:$f}' "$f" 2>/dev/null || true)
    [[ -n "$line" ]] && EMAIL_EVENTS+="$line"$'\n'
  done
fi

# ── Merge + sort by ts ───────────────────────────────────
# pipefail makes grep's "no matches" exit-1 collapse the whole pipeline; trap
# that and fall back to an empty array.
RAW=$(printf '%s\n%s\n%s\n%s\n' "$DISPATCH_EVENTS" "$ISSUE_EVENTS" "$PR_EVENTS" "$EMAIL_EVENTS" | grep -v '^$' || true)
if [[ -z "$RAW" ]]; then
  ALL='[]'
else
  ALL=$(echo "$RAW" | jq -s 'sort_by(.ts // "")' 2>/dev/null || echo "[]")
fi

# ── Output ──────────────────────────────────────────────
if [[ "$JSON_OUT" == "true" ]]; then
  jq -n --argjson card "$CARD" --argjson state "$STATE" --argjson events "$ALL" --arg pr "$PR_NUM" \
    '{card:$card, pr:$pr, state:$state, events:$events}'
else
  echo "=== Card #${CARD} timeline ==="
  if [[ -n "$PR_NUM" ]]; then echo "Linked PR: #${PR_NUM}"; fi
  echo ""
  echo "## State"
  echo "$STATE" | jq -r 'to_entries[] | "  \(.key) = \(.value)"'
  echo ""
  echo "## Events (chronological)"
  echo "$ALL" | jq -r '.[] |
    if .source == "dispatch" and .agent == "vision-qa" then
      "  \(.ts)  VISION-QA \(.outcome // "?")  \(.error // "")"
    elif .source == "dispatch" then
      "  \(.ts)  DISPATCH  \(.agent // "?")  \(.outcome // "?")  \(.reason // .error // "")"
    elif .source == "email" then
      "  \(.ts)  EMAIL     \(.kind // "?")  \(.subject // "")  sent=\(.sent)"
    elif (.source | startswith("pr#")) then
      "  \(.ts)  \(.source)   \(.event // "?")  by \(.actor // "?")  \(.label // "")"
    else
      "  \(.ts)  ISSUE     \(.event // "?")  by \(.actor // "?")  \(.label // "")"
    end'
fi
