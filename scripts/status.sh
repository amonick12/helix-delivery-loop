#!/bin/bash
# status.sh — Pipeline health at a glance.
#
# Usage:
#   ./status.sh
#
# Output: one-screen summary of board, PRs, agents, comments, stuck cards, next dispatch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
status.sh — Pipeline health at a glance.

Usage:
  ./status.sh

Shows:
  - Board: cards per column
  - Open PRs: number, checklist progress, labels, last comment
  - Active agents: from state file
  - Unaddressed comments: from check-pr-comments.sh
  - Stuck cards: from dispatcher stuck check
  - Next dispatch: from dispatcher --dry-run
HELP

echo "═══════════════════════════════════════════════════"
echo "  DELIVERY LOOP STATUS  $(date +%Y-%m-%d\ %H:%M)"
echo "═══════════════════════════════════════════════════"

# ── Gmail MCP sentinel (loud alert) ─────────────────────
GMAIL_DOWN="/tmp/helix-gmail-mcp-down"
if [[ -f "$GMAIL_DOWN" ]]; then
  echo ""
  echo "⚠️  GMAIL MCP IS DOWN — emails are queued but unsent"
  cat "$GMAIL_DOWN"
  echo "    Fix: run /mcp and authenticate 'claude.ai Gmail'"
fi

# ── Awaiting your approval (highest-priority info) ──────
echo ""
QUEUE_DIR="${EPIC_EMAIL_QUEUE_DIR:-/tmp/helix-epic-emails-pending}"
WAITING=()
if [[ -d "$QUEUE_DIR" ]]; then
  for f in "$QUEUE_DIR"/design-*.json "$QUEUE_DIR"/epic-*.json "$QUEUE_DIR"/dead-letter-*.json; do
    [[ -f "$f" ]] || continue
    sent=$(jq -r '.sent // false' "$f" 2>/dev/null || echo "false")
    [[ "$sent" == "true" ]] || continue   # not yet emailed → user hasn't seen it
    kind=$(jq -r '.kind // "approval"' "$f" 2>/dev/null || echo "approval")
    card=$(jq -r '.card // .epic // 0' "$f" 2>/dev/null || echo "0")
    sent_at=$(jq -r '.created_at // ""' "$f" 2>/dev/null || echo "")
    if [[ -n "$sent_at" && "$sent_at" != "null" ]]; then
      now_epoch=$(date +%s)
      sent_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$sent_at" +%s 2>/dev/null || echo "$now_epoch")
      hours=$(( (now_epoch - sent_epoch) / 3600 ))
      WAITING+=("  ⏳ #${card}  ${kind}  emailed ${hours}h ago")
    else
      WAITING+=("  ⏳ #${card}  ${kind}  emailed (time unknown)")
    fi
  done
fi
echo "── Awaiting your approval ────────────────────────"
if [[ ${#WAITING[@]} -eq 0 ]]; then
  echo "  ✓  Nothing waiting on you. Loop is autonomous."
else
  for line in "${WAITING[@]}"; do echo "$line"; done
fi

# ── Board summary ──────────────────────────────────────
echo ""
echo "── Board ──────────────────────────────────────────"
BOARD_JSON=$(bash "$SCRIPTS_DIR/read-board.sh" 2>/dev/null || echo '{"cards":[]}')

# Single jq pass: group cards by normalized status, emit one line per column
echo "$BOARD_JSON" | jq -r '
  ["Backlog","Ready","In Progress","In Review","Done"] as $cols |
  # Build a lookup: lowercase status -> list of card summaries
  ([.cards[] | {s: (.fields.Status // "No Status" | ascii_downcase), label: "#\(.issue_number) \(.title[:40])"}]
   | group_by(.s) | map({key: .[0].s, value: [.[] | .label]}) | from_entries) as $grouped |
  $cols[] |
  . as $col |
  ($col | ascii_downcase) as $key |
  ($grouped[$key] // []) as $cards |
  if ($cards | length) > 0
  then "  \($col):~\($cards | length)  (\($cards | join(", ")))"
  else "  \($col):~\($cards | length)"
  end
' | while IFS='~' read -r label rest; do
  printf "%-14s %s\n" "$label" "$rest"
done

# ── Open PRs ───────────────────────────────────────────
echo ""
echo "── Open PRs ───────────────────────────────────────"
PR_JSON=$(gh pr list --repo "$REPO" --state open --json number,title,labels,comments --limit 20 2>/dev/null || echo "[]")
PR_COUNT=$(echo "$PR_JSON" | jq 'length')

if [[ "$PR_COUNT" -eq 0 ]]; then
  echo "  None"
else
  echo "$PR_JSON" | jq -r '.[] | "  PR #\(.number) \(.title[:45])  labels=[\([.labels[].name] | join(","))]  comments=\(.comments | length)"'
fi

# ── Active agents (from state) ─────────────────────────
echo ""
echo "── Active Agents ──────────────────────────────────"
if [[ -f "$STATE_FILE" ]]; then
  ACTIVE=$(jq -r '.cards | to_entries[] | select(.value.last_agent != null) | "  Card #\(.key): \(.value.last_agent)  updated=\(.value.last_updated // "?")"' "$STATE_FILE" 2>/dev/null)
  if [[ -n "$ACTIVE" ]]; then
    echo "$ACTIVE"
    # Check timers
    jq -r '.cards | to_entries[] | select(.value.timer_start != null and .value.timer_start != 0) | .key' "$STATE_FILE" 2>/dev/null | while read -r card_id; do
      bash "$SCRIPTS_DIR/state.sh" check-timer "$card_id" "$(jq -r --arg id "$card_id" '.cards[$id].timer_agent // "unknown"' "$STATE_FILE")" 2>/dev/null | sed 's/^/  /' || true
    done
  else
    echo "  None"
  fi
else
  echo "  No state file"
fi

# ── Unaddressed comments ──────────────────────────────
echo ""
echo "── Unaddressed Comments ───────────────────────────"
COMMENTS_JSON=$(bash "$SCRIPTS_DIR/check-pr-comments.sh" 2>/dev/null || echo "[]")
COMMENT_COUNT=$(echo "$COMMENTS_JSON" | jq 'length' 2>/dev/null || echo 0)
if [[ "$COMMENT_COUNT" -eq 0 ]]; then
  echo "  None"
else
  echo "$COMMENTS_JSON" | jq -r '.[] | "  PR #\(.pr) (card #\(.card)): \(.author) — \(.comment[:60])"' 2>/dev/null
fi

# ── Stuck cards ────────────────────────────────────────
echo ""
echo "── Stuck Cards ────────────────────────────────────"
if [[ -f "$STATE_FILE" ]]; then
  NOW=$(date +%s)
  STUCK_FOUND=false
  jq -r '.cards | to_entries[] | select(.value.last_updated != null) | "\(.key) \(.value.last_updated) \(.value.last_agent // "none")"' "$STATE_FILE" 2>/dev/null | while read -r card_id updated agent; do
    # Parse ISO timestamp to epoch (macOS date)
    updated_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$updated" +%s 2>/dev/null || echo 0)
    elapsed=$(( NOW - updated_epoch ))
    if [[ $elapsed -gt 3600 ]]; then
      elapsed_min=$(( elapsed / 60 ))
      echo "  Card #$card_id: $agent stale for ${elapsed_min}m"
      STUCK_FOUND=true
    fi
  done
  if [[ "$STUCK_FOUND" != "true" ]]; then
    echo "  None"
  fi
else
  echo "  No state file"
fi

# ── Dead-lettered cards ───────────────────────────────
echo ""
echo "── Dead-Lettered Cards ────────────────────────────"
DL_CARDS=$(echo "$BOARD_JSON" | jq '[.cards[] | select(any(.labels[]; . == "dead-letter"))] | length' 2>/dev/null || echo 0)
if [[ "$DL_CARDS" -eq 0 ]]; then
  echo "  None"
else
  echo "$BOARD_JSON" | jq -r '.cards[] | select(any(.labels[]; . == "dead-letter")) | "  #\(.issue_number) \(.title[:40]) — remove dead-letter label to retry"'
fi

# ── Recent failures ───────────────────────────────────
echo ""
echo "── Recent Failures (last 5) ─────────────────────"
DISPATCH_LOG="$HELIX_REPO_ROOT/.claude/plugins/helix-delivery-loop/logs/dispatch-log.jsonl"
if [[ -f "$DISPATCH_LOG" ]]; then
  ALL_FAILURES=$(bash "$SCRIPTS_DIR/dispatch-log.sh" query --outcome preflight_fail --last 5 2>/dev/null || echo "[]")
  AGENT_ERRORS=$(bash "$SCRIPTS_DIR/dispatch-log.sh" query --outcome agent_error --last 5 2>/dev/null || echo "[]")
  COMBINED=$(echo "$ALL_FAILURES $AGENT_ERRORS" | jq -s '.[0] + .[1] | sort_by(.ts) | reverse | .[0:5]')
  FAIL_COUNT=$(echo "$COMBINED" | jq 'length')
  if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo "  None"
  else
    echo "$COMBINED" | jq -r '.[] | "  \(.ts[11:16]) card=#\(.card) \(.agent) → \(.outcome)\(if .error then ": \(.error[:50])" else "" end)"'
  fi
else
  echo "  No dispatch log"
fi

# ── Throughput ────────────────────────────────────────
echo ""
echo "── Throughput ─────────────────────────────────────"
if [[ -f "$DISPATCH_LOG" ]]; then
  STATS_24H=$(bash "$SCRIPTS_DIR/dispatch-log.sh" stats --hours 24 2>/dev/null || echo '{}')
  STATS_168H=$(bash "$SCRIPTS_DIR/dispatch-log.sh" stats --hours 168 2>/dev/null || echo '{}')
  echo "  Last 24h: $(echo "$STATS_24H" | jq -r '.success // 0') successful, $(echo "$STATS_24H" | jq -r '.agent_error // 0') errors, avg $(echo "$STATS_24H" | jq -r '.avg_duration_s // 0')s"
  echo "  Last 7d:  $(echo "$STATS_168H" | jq -r '.success // 0') successful, $(echo "$STATS_168H" | jq -r '.agent_error // 0') errors"
else
  echo "  No dispatch log"
fi

# ── Next dispatch ──────────────────────────────────────
echo ""
echo "── Next Dispatch ──────────────────────────────────"
DISPATCH=$(bash "$SCRIPTS_DIR/dispatcher.sh" --dry-run 2>/dev/null || echo '{"agent":"none","reason":"dispatcher failed"}')
AGENT=$(echo "$DISPATCH" | jq -r '.agent // "none"')
CARD=$(echo "$DISPATCH" | jq -r '.card // "?"')
REASON=$(echo "$DISPATCH" | jq -r '.reason // "?"')
echo "  Agent: $AGENT  Card: #$CARD  Reason: $REASON"

echo ""
echo "═══════════════════════════════════════════════════"
