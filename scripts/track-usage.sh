#!/bin/bash
# track-usage.sh — Token and cost tracking per agent per card.
#
# Usage:
#   ./track-usage.sh start --card 137 --agent planner
#   ./track-usage.sh end --card 137 --agent planner \
#     --input-tokens 45000 --output-tokens 12000 --model opus
#   ./track-usage.sh card --card 137
#   ./track-usage.sh post --card 137
#   ./track-usage.sh summary
#
# Requires: jq, bc, gh (for post)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
track-usage.sh — Token and cost tracking per agent per card.

Commands:
  start   --card <N> --agent <name>           Begin tracking a run
  end     --card <N> --agent <name>           Record result
            --input-tokens <N> --output-tokens <N> --model <name>
  card    --card <N>                          Show card totals
  post    --card <N>                          Post to GitHub issue
  summary                                     All active cards

Requires: jq, bc, gh (for post)
HELP

# ── Ensure USAGE_DIR exists ─────────────────────────────
mkdir -p "$USAGE_DIR"

# ── Parse subcommand ────────────────────────────────────
COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
  echo "Error: subcommand required (start|end|card|post|summary)" >&2
  exit 1
fi
shift

# ── Parse flags ─────────────────────────────────────────
CARD=""
AGENT=""
INPUT_TOKENS=""
OUTPUT_TOKENS=""
MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)           CARD="$2"; shift 2 ;;
    --agent)          AGENT="$2"; shift 2 ;;
    --input-tokens)   INPUT_TOKENS="$2"; shift 2 ;;
    --output-tokens)  OUTPUT_TOKENS="$2"; shift 2 ;;
    --model)          MODEL="$2"; shift 2 ;;
    *)                echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ─────────────────────────────────────────────
usage_file() {
  echo "$USAGE_DIR/${1}.json"
}

now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ensure_usage_file() {
  local card="$1"
  local f; f="$(usage_file "$card")"
  if [[ ! -f "$f" ]]; then
    jq -n --argjson card "$card" '{card: $card, runs: [], totals: {input_tokens: 0, output_tokens: 0, cost_usd: 0, duration_sec: 0}}' > "$f"
  fi
}

calculate_cost() {
  local input_tokens="$1"
  local output_tokens="$2"
  local model="$3"

  local cost_input cost_output
  case "$model" in
    opus)   cost_input="$COST_INPUT_OPUS";   cost_output="$COST_OUTPUT_OPUS" ;;
    sonnet) cost_input="$COST_INPUT_SONNET"; cost_output="$COST_OUTPUT_SONNET" ;;
    haiku)  cost_input="$COST_INPUT_HAIKU";  cost_output="$COST_OUTPUT_HAIKU" ;;
    *)      log_error "Unknown model: $model"; exit 1 ;;
  esac

  echo "scale=6; ($input_tokens / 1000000 * $cost_input) + ($output_tokens / 1000000 * $cost_output)" | bc
}

recalc_totals() {
  local f="$1"
  jq '.totals = (.runs | map(select(.ended != null)) | {
    input_tokens: (map(.input_tokens) | add // 0),
    output_tokens: (map(.output_tokens) | add // 0),
    cost_usd: (map(.cost_usd) | add // 0),
    duration_sec: (map(.duration_sec) | add // 0)
  })' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

# ── Commands ────────────────────────────────────────────

cmd_start() {
  if [[ -z "$CARD" || -z "$AGENT" ]]; then
    echo "Error: --card and --agent required for start" >&2
    exit 1
  fi

  ensure_usage_file "$CARD"
  local f; f="$(usage_file "$CARD")"
  local ts; ts="$(now_utc)"

  jq --arg agent "$AGENT" --arg started "$ts" \
    '.runs += [{agent: $agent, model: null, input_tokens: 0, output_tokens: 0, cost_usd: 0, started: $started, ended: null, duration_sec: 0}]' \
    "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"

  log_info "Started tracking card $CARD agent $AGENT at $ts"
}

cmd_end() {
  if [[ -z "$CARD" || -z "$AGENT" || -z "$INPUT_TOKENS" || -z "$OUTPUT_TOKENS" || -z "$MODEL" ]]; then
    echo "Error: --card, --agent, --input-tokens, --output-tokens, --model required for end" >&2
    exit 1
  fi

  ensure_usage_file "$CARD"
  local f; f="$(usage_file "$CARD")"
  local ts; ts="$(now_utc)"
  local cost; cost="$(calculate_cost "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$MODEL")"

  # Find the latest run for this agent that hasn't ended yet and update it
  jq --arg agent "$AGENT" --arg ended "$ts" --arg model "$MODEL" \
     --argjson input "$INPUT_TOKENS" --argjson output "$OUTPUT_TOKENS" \
     --argjson cost "$cost" \
    '
    ([.runs | to_entries[] | select(.value.agent == $agent and .value.ended == null) | .key] | last // -1) as $idx |
    if $idx >= 0 then
      .runs[$idx] += {
        model: $model,
        input_tokens: $input,
        output_tokens: $output,
        cost_usd: $cost,
        ended: $ended,
        duration_sec: 0
      }
    else
      .runs += [{
        agent: $agent,
        model: $model,
        input_tokens: $input,
        output_tokens: $output,
        cost_usd: $cost,
        started: $ended,
        ended: $ended,
        duration_sec: 0
      }]
    end
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"

  # Calculate duration using date math (portable)
  local started_ts ended_ts duration
  started_ts=$(jq -r --arg agent "$AGENT" '[.runs[] | select(.agent == $agent and .ended != null)] | last | .started' "$f")
  ended_ts="$ts"

  # Convert ISO timestamps to epoch for duration
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_ts" +%s &>/dev/null; then
    local s_epoch e_epoch
    s_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_ts" +%s 2>/dev/null)
    e_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ended_ts" +%s 2>/dev/null)
    duration=$(( e_epoch - s_epoch ))
  else
    # GNU date fallback
    local s_epoch e_epoch
    s_epoch=$(date -d "$started_ts" +%s 2>/dev/null || echo 0)
    e_epoch=$(date -d "$ended_ts" +%s 2>/dev/null || echo 0)
    duration=$(( e_epoch - s_epoch ))
  fi

  # Update duration on the last ended run for this agent
  jq --arg agent "$AGENT" --argjson dur "$duration" \
    '([.runs | to_entries[] | select(.value.agent == $agent and .value.ended != null) | .key] | last // -1) as $idx |
     if $idx >= 0 then .runs[$idx].duration_sec = $dur else . end' \
    "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"

  recalc_totals "$f"

  log_info "Ended tracking card $CARD agent $AGENT: ${INPUT_TOKENS}in/${OUTPUT_TOKENS}out model=$MODEL cost=\$${cost}"
}

cmd_card() {
  if [[ -z "$CARD" ]]; then
    echo "Error: --card required" >&2
    exit 1
  fi

  local f; f="$(usage_file "$CARD")"
  if [[ ! -f "$f" ]]; then
    echo "No usage data for card $CARD" >&2
    exit 1
  fi

  jq '.' "$f"
}

cmd_post() {
  if [[ -z "$CARD" ]]; then
    echo "Error: --card required for post" >&2
    exit 1
  fi

  local f; f="$(usage_file "$CARD")"
  if [[ ! -f "$f" ]]; then
    echo "No usage data for card $CARD" >&2
    exit 1
  fi

  # Build markdown table
  local body
  body=$(jq -r '
    "## Token Usage — Card #\(.card)\n\n" +
    "| Agent | Model | Input | Output | Cost | Duration |\n" +
    "|-------|-------|------:|-------:|-----:|---------:|\n" +
    (.runs | map(select(.ended != null)) | map(
      "| \(.agent) | \(.model) | \(.input_tokens | tostring) | \(.output_tokens | tostring) | $\(.cost_usd | tostring) | \(.duration_sec)s |"
    ) | join("\n")) +
    "\n\n**Totals:** \(.totals.input_tokens) input, \(.totals.output_tokens) output, $\(.totals.cost_usd) cost, \(.totals.duration_sec)s"
  ' "$f")

  # Get total cost for the AgentCost field
  local total_cost
  total_cost=$(jq -r '.totals.cost_usd' "$f")

  if [[ "${DRY_RUN:-}" == "true" || "${DRY_RUN:-}" == "1" ]]; then
    echo "$body"
    log_info "DRY_RUN: skipping gh issue comment + PR comment + AgentCost field"
  else
    # Post to the issue
    gh issue comment "$CARD" --repo "$REPO" --body "$body" 2>/dev/null || true
    log_info "Posted usage to issue #$CARD"

    # Post to the PR (if one exists for this card)
    local pr_number
    pr_number=$(gh pr list --repo "$REPO" --search "Closes #$CARD" --json number --jq '.[0].number' 2>/dev/null || echo "")
    if [[ -z "$pr_number" ]]; then
      # Try finding by branch pattern
      pr_number=$(gh pr list --repo "$REPO" --head "feature/${CARD}-" --json number --jq '.[0].number' 2>/dev/null || echo "")
    fi
    if [[ -n "$pr_number" ]]; then
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" 2>/dev/null || true
      log_info "Posted usage to PR #$pr_number"
    fi

    # Set AgentCost field on the board card
    if [[ -f "$SCRIPTS_DIR/set-field.sh" ]]; then
      bash "$SCRIPTS_DIR/set-field.sh" --issue "$CARD" --field "AgentCost" --value "\$${total_cost}" 2>/dev/null || true
      log_info "Set AgentCost=\$${total_cost} on card #$CARD"
    fi
  fi
}

cmd_summary() {
  local total_input=0 total_output=0 total_duration=0
  local total_cost="0"
  local found=0

  echo "## Delivery Loop Usage Summary"
  echo ""
  echo "| Card | Runs | Input | Output | Cost | Duration |"
  echo "|-----:|-----:|------:|-------:|-----:|---------:|"

  for f in "$USAGE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    found=1

    local card runs input output cost duration
    card=$(jq -r '.card' "$f")
    runs=$(jq '.runs | map(select(.ended != null)) | length' "$f")
    input=$(jq '.totals.input_tokens' "$f")
    output=$(jq '.totals.output_tokens' "$f")
    cost=$(jq '.totals.cost_usd' "$f")
    duration=$(jq '.totals.duration_sec' "$f")

    echo "| #$card | $runs | $input | $output | \$$cost | ${duration}s |"

    total_input=$(( total_input + input ))
    total_output=$(( total_output + output ))
    total_duration=$(( total_duration + duration ))
    total_cost=$(echo "scale=6; $total_cost + $cost" | bc)
  done

  if [[ $found -eq 0 ]]; then
    echo "| — | — | — | — | — | — |"
  fi

  echo ""
  echo "**Grand totals:** $total_input input, $total_output output, \$$total_cost cost, ${total_duration}s"
}

# ── Dispatch ────────────────────────────────────────────
case "$COMMAND" in
  start)   cmd_start ;;
  end)     cmd_end ;;
  card)    cmd_card ;;
  post)    cmd_post ;;
  summary) cmd_summary ;;
  *)       echo "Error: unknown command '$COMMAND'" >&2; exit 1 ;;
esac
