#!/bin/bash
# drain-emails.sh — own the email queue lifecycle so the orchestrator only
# has to do the two things shell can't: spawn a vision-QA subagent and call
# the Gmail MCP send tool. Everything else (queue scan, retry counter,
# sentinel management, dead-letter escalation, label flips) is here.
#
# Usage:
#   ./drain-emails.sh plan      # print a JSON list of actions for the orchestrator
#   ./drain-emails.sh mark-vision-pass  --file <path> [--note "..."]
#   ./drain-emails.sh mark-vision-fail  --file <path> --failures <json-array>
#   ./drain-emails.sh mark-sent         --file <path>
#   ./drain-emails.sh mark-mcp-down     --reason "..." --queued <int>
#   ./drain-emails.sh mark-mcp-up
#
# `plan` output schema (JSON array):
#   [{
#     "action": "vision_qa" | "send" | "skip",
#     "file": "/path/to/queue.json",
#     "card": <int>,
#     "kind": "design"|"testflight"|"dead-letter",
#     "screenshots": [...],
#     "retries": <int>,
#     "context": "<short summary>"
#   }, ...]
#
# The orchestrator walks the plan, performs the per-action MCP work, then
# calls back with mark-vision-pass/mark-vision-fail/mark-sent. All the
# stateful bookkeeping (incrementing retries, writing dead-letter files,
# managing the .sending/.sent sentinels, applying GitHub labels, posting
# bot comments) happens here, NOT in the orchestrator's prompt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
drain-emails.sh — email queue lifecycle owned by shell, MCP calls owned by orchestrator.

Subcommands:
  plan                                 emit JSON plan for the orchestrator
  mark-vision-pass --file <p> [--note] flip vision_qa_passed=true on success
  mark-vision-fail --file <p> --failures <json>  increment retries; dead-letter at >=3
  mark-sent        --file <p>          rename sentinel to .sent + jq sent:true
  mark-mcp-down    --reason "..." --queued <n>   write the loud sentinel
  mark-mcp-up                          remove the sentinel

The orchestrator reads `plan`, performs MCP work per action, calls back.
HELP

QUEUE_DIR="${EPIC_EMAIL_QUEUE_DIR:-/tmp/helix-epic-emails-pending}"
GMAIL_DOWN_SENTINEL="/tmp/helix-gmail-mcp-down"
MAX_VISION_RETRIES=3

cmd="${1:-}"; shift 2>/dev/null || true

# ── plan ─────────────────────────────────────────────────
plan() {
  mkdir -p "$QUEUE_DIR"
  # Clear stale Gmail-down sentinel at the start of every drain cycle. Each
  # send attempt that fails will rewrite it; if all sends succeed (or there
  # are no sends), the sentinel stays cleared. Avoids the case where Gmail
  # came back online but the sentinel stuck because no send happened to clear it.
  rm -f "$GMAIL_DOWN_SENTINEL"
  local actions='[]'

  # Scan all queue files in stable order
  local files=()
  for pattern in dead-letter design epic; do
    while IFS= read -r f; do
      [[ -n "$f" ]] && files+=("$f")
    done < <(find "$QUEUE_DIR" -maxdepth 1 -name "${pattern}-*.json" 2>/dev/null | sort)
  done

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    local sent vision_passed kind card retries
    sent=$(jq -r '.sent // false' "$f" 2>/dev/null || echo "false")
    # NOTE: jq `//` treats `false` as falsy, so `// true` would override an
    # explicit `false`. Use `// false` so missing-or-false → vision_qa, only
    # explicit `true` → send. (`if has(...) then ... else ... end` would also
    # work; `// false` is shorter.)
    vision_passed=$(jq -r '.vision_qa_passed // false' "$f" 2>/dev/null || echo "false")
    kind=$(jq -r '.kind // "unknown"' "$f" 2>/dev/null || echo "unknown")
    card=$(jq -r '.card // .epic // 0' "$f" 2>/dev/null || echo 0)
    retries=$(jq -r '.vision_qa_retries // 0' "$f" 2>/dev/null || echo 0)

    # Already sent? Skip.
    if [[ "$sent" == "true" || -f "${f}.sent" ]]; then
      continue
    fi

    # Vision QA needed (design + testflight only; dead-letter skips QA)?
    if [[ "$kind" != "dead-letter" && "$vision_passed" != "true" ]]; then
      local screenshots
      screenshots=$(jq -c '.screenshots // []' "$f")
      actions=$(echo "$actions" | jq \
        --arg file "$f" \
        --arg kind "$kind" \
        --argjson card "$card" \
        --argjson retries "$retries" \
        --argjson screenshots "$screenshots" \
        '. + [{action:"vision_qa", file:$file, kind:$kind, card:$card, retries:$retries, screenshots:$screenshots}]')
      continue
    fi

    # Ready to send.
    local subject body to
    subject=$(jq -r '.subject // ""' "$f")
    body=$(jq -r '.body // ""' "$f")
    to=$(jq -r '.to // ""' "$f")
    actions=$(echo "$actions" | jq \
      --arg file "$f" \
      --arg kind "$kind" \
      --argjson card "$card" \
      --arg subject "$subject" \
      --arg body "$body" \
      --arg to "$to" \
      '. + [{action:"send", file:$file, kind:$kind, card:$card, to:$to, subject:$subject, body:$body}]')
  done

  echo "$actions"
}

# ── mark-vision-pass ─────────────────────────────────────
mark_vision_pass() {
  local file="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) file="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      *)      shift ;;
    esac
  done
  [[ -z "$file" || ! -f "$file" ]] && { log_error "--file required and must exist"; return 1; }

  local tmp
  tmp=$(mktemp)
  jq '.vision_qa_passed = true' "$file" > "$tmp" && mv "$tmp" "$file"
  log_info "Vision QA passed: $(basename "$file")"

  # Append a dispatch-log entry so /delivery-loop trace surfaces it
  local card
  card=$(jq -r '.card // .epic // 0' "$file")
  bash "$SCRIPT_DIR/dispatch-log.sh" append \
    --card "$card" \
    --agent "vision-qa" \
    --outcome "pass" \
    --error "${note:-clean}" 2>/dev/null || true
}

# ── mark-vision-fail ─────────────────────────────────────
mark_vision_fail() {
  local file="" failures="[]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)     file="$2"; shift 2 ;;
      --failures) failures="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done
  [[ -z "$file" || ! -f "$file" ]] && { log_error "--file required and must exist"; return 1; }

  local card kind retries new_retries
  card=$(jq -r '.card // .epic // 0' "$file")
  kind=$(jq -r '.kind // "unknown"' "$file")
  retries=$(jq -r '.vision_qa_retries // 0' "$file")
  new_retries=$(( retries + 1 ))

  # Increment counter on disk
  local tmp
  tmp=$(mktemp)
  jq --argjson n "$new_retries" '.vision_qa_retries = $n' "$file" > "$tmp" && mv "$tmp" "$file"

  # Always log the failure
  bash "$SCRIPT_DIR/dispatch-log.sh" append \
    --card "$card" \
    --agent "vision-qa" \
    --outcome "fail" \
    --error "$(echo "$failures" | jq -r 'tostring' | head -c 500)" 2>/dev/null || true

  if (( new_retries >= MAX_VISION_RETRIES )); then
    # Dead-letter escalation: delete the original queue file, write a
    # dead-letter so the user is notified, label the card for visibility.
    log_warn "Vision QA failed $new_retries times on $(basename "$file") — dead-lettering"
    local body
    body="Vision QA failed ${new_retries}× on the auto-rendered mockups for card #${card}. The loop has stopped trying to ship this without your review.\n\n**Failures:**\n\n\`\`\`\n$(echo "$failures" | jq -r '.[]' 2>/dev/null || echo "$failures")\n\`\`\`"
    local dl="$QUEUE_DIR/dead-letter-${card}.json"
    jq -n \
      --arg to "${EPIC_NOTIFY_TO:-amonick12@gmail.com}" \
      --arg subject "[Helix] Vision QA stuck on card #${card} after ${new_retries} attempts — manual review needed" \
      --arg body "$body" \
      --argjson card "$card" \
      --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{to:$to, subject:$subject, body:$body, card:$card, kind:"dead-letter", agent:"vision-qa", fail_count:$card, created_at:$created_at, sent:false}' \
      > "$dl"
    rm -f "$file"
    gh issue edit "$card" --repo "$REPO" --add-label "dead-letter" 2>/dev/null || true
    return 0
  fi

  # Below the retry cap: route back to the agent who can fix it.
  case "$kind" in
    design)
      gh issue edit "$card" --repo "$REPO" --add-label "redesign-needed" 2>/dev/null || true
      log_info "Marked card #${card} 'redesign-needed' (attempt ${new_retries}/${MAX_VISION_RETRIES})"
      ;;
    testflight)
      local last_pr
      last_pr=$(jq -r '.last_pr // 0' "$file")
      if [[ "$last_pr" != "0" ]]; then
        gh pr edit "$last_pr" --repo "$REPO" --add-label "rework" 2>/dev/null || true
        gh pr ready "$last_pr" --repo "$REPO" --undo 2>/dev/null || true
        log_info "Routed PR #${last_pr} to Builder rework (attempt ${new_retries}/${MAX_VISION_RETRIES})"
      fi
      ;;
  esac
}

# ── mark-sent ────────────────────────────────────────────
mark_sent() {
  local file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file) file="$2"; shift 2 ;;
      *)      shift ;;
    esac
  done
  [[ -z "$file" ]] && { log_error "--file required"; return 1; }

  # Sentinel rename first (atomic-ish), then jq edit.
  if [[ -f "${file}.sending" ]]; then
    mv "${file}.sending" "${file}.sent"
  else
    : > "${file}.sent"
  fi
  if [[ -f "$file" ]]; then
    local tmp
    tmp=$(mktemp)
    jq '.sent = true' "$file" > "$tmp" && mv "$tmp" "$file"
  fi
  rm -f "$GMAIL_DOWN_SENTINEL"
  log_info "Marked sent: $(basename "$file")"
}

# ── mark-mcp-down ────────────────────────────────────────
mark_mcp_down() {
  local reason="" queued=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason)  reason="$2"; shift 2 ;;
      --queued)  queued="$2"; shift 2 ;;
      *)         shift ;;
    esac
  done
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reason "$reason" \
    --argjson queued "$queued" \
    '{failed_at:$ts, reason:$reason, queued_count:$queued}' \
    > "$GMAIL_DOWN_SENTINEL"
  log_warn "Gmail MCP down sentinel written"
}

# ── mark-mcp-up ──────────────────────────────────────────
mark_mcp_up() {
  rm -f "$GMAIL_DOWN_SENTINEL"
}

case "$cmd" in
  plan)              plan ;;
  mark-vision-pass)  mark_vision_pass "$@" ;;
  mark-vision-fail)  mark_vision_fail "$@" ;;
  mark-sent)         mark_sent "$@" ;;
  mark-mcp-down)     mark_mcp_down "$@" ;;
  mark-mcp-up)       mark_mcp_up "$@" ;;
  *)
    log_error "Usage: drain-emails.sh {plan|mark-vision-pass|mark-vision-fail|mark-sent|mark-mcp-down|mark-mcp-up} [args]"
    exit 1
    ;;
esac
