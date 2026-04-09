#!/bin/bash
# learnings.sh — Persistent learning system for the delivery loop.
# Manages a knowledge base at .claude/delivery-loop-learnings.json
#
# Commands:
#   learnings.sh record  --card N --agent <agent> --type <type> --lesson "..." [--context "..."] [--resolution "..."] [--tags "a,b,c"]
#   learnings.sh query   --agent <agent> [--type <type>] [--limit 5]
#   learnings.sh stats
#   learnings.sh prune   [--older-than 90d]
#   learnings.sh recommend
#
# Types: gate-failure, rework-cause, pattern, pitfall, performance
#
# Requires: jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
learnings.sh — Persistent learning system for the delivery loop.

Commands:
  record   --card N --agent <agent> --type <type> --lesson "..." [--context "..."] [--resolution "..."] [--tags "a,b,c"]
  query    --agent <agent> [--type <type>] [--limit 5]
  stats    Show aggregate patterns
  prune    [--older-than 90d]  Remove old learnings
  recommend  Suggest optimizations based on patterns

Types: gate-failure, rework-cause, pattern, pitfall, performance
HELP

# ── Paths ──────────────────────────────────────────────────
LEARNINGS_FILE="${LEARNINGS_FILE:-$REPO_ROOT/.claude/delivery-loop-learnings.json}"
VALID_TYPES="gate-failure rework-cause pattern pitfall performance"
VALID_AGENTS="scout designer planner builder reviewer tester releaser"

DRY_RUN="${DRY_RUN:-0}"

# ── Helpers ────────────────────────────────────────────────
is_valid_type() {
  local t="$1"
  for v in $VALID_TYPES; do
    [[ "$v" == "$t" ]] && return 0
  done
  return 1
}

is_valid_agent() {
  local a="$1"
  for v in $VALID_AGENTS; do
    [[ "$v" == "$a" ]] && return 0
  done
  return 1
}

ensure_file() {
  if [[ ! -f "$LEARNINGS_FILE" ]]; then
    mkdir -p "$(dirname "$LEARNINGS_FILE")"
    echo '{"learnings":[],"stats":{"total":0,"by_type":{},"by_agent":{},"most_common_tags":[]}}' > "$LEARNINGS_FILE"
  fi
}

next_id() {
  local max_id
  max_id=$(jq '[.learnings[].id] | max // 0' "$LEARNINGS_FILE")
  echo $((max_id + 1))
}

rebuild_stats() {
  local tmp
  tmp=$(jq '
    .stats.total = (.learnings | length) |
    .stats.by_type = (.learnings | group_by(.type) | map({key: .[0].type, value: length}) | from_entries) |
    .stats.by_agent = (.learnings | group_by(.agent) | map({key: .[0].agent, value: length}) | from_entries) |
    .stats.most_common_tags = (
      [.learnings[].tags // [] | .[]] |
      group_by(.) | map({tag: .[0], count: length}) |
      sort_by(-.count) | .[0:10] | map(.tag)
    )
  ' "$LEARNINGS_FILE")
  echo "$tmp" > "$LEARNINGS_FILE"
}

# ── Command: record ────────────────────────────────────────
cmd_record() {
  local card="" agent="" type="" lesson="" context="" resolution="" tags=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --card)       card="$2"; shift 2 ;;
      --agent)      agent="$2"; shift 2 ;;
      --type)       type="$2"; shift 2 ;;
      --lesson)     lesson="$2"; shift 2 ;;
      --context)    context="$2"; shift 2 ;;
      --resolution) resolution="$2"; shift 2 ;;
      --tags)       tags="$2"; shift 2 ;;
      *)            echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
  done

  # Validate required fields
  if [[ -z "$card" || -z "$agent" || -z "$type" || -z "$lesson" ]]; then
    echo "Error: --card, --agent, --type, and --lesson are required" >&2
    exit 1
  fi

  if ! is_valid_agent "$agent"; then
    echo "Error: unknown agent '$agent'. Valid: $VALID_AGENTS" >&2
    exit 1
  fi

  if ! is_valid_type "$type"; then
    echo "Error: unknown type '$type'. Valid: $VALID_TYPES" >&2
    exit 1
  fi

  ensure_file

  local id
  id=$(next_id)
  local created
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Build tags array
  local tags_json="[]"
  if [[ -n "$tags" ]]; then
    tags_json=$(echo "$tags" | tr ',' '\n' | jq -R . | jq -s .)
  fi

  # Add the learning
  local tmp
  tmp=$(jq --argjson id "$id" \
           --argjson card "$card" \
           --arg agent "$agent" \
           --arg type "$type" \
           --arg lesson "$lesson" \
           --arg context "$context" \
           --arg resolution "$resolution" \
           --argjson tags "$tags_json" \
           --arg created "$created" \
    '.learnings += [{
      id: $id,
      card: $card,
      agent: $agent,
      type: $type,
      lesson: $lesson,
      context: (if $context == "" then null else $context end),
      resolution: (if $resolution == "" then null else $resolution end),
      tags: $tags,
      created: $created
    }]' "$LEARNINGS_FILE")
  echo "$tmp" > "$LEARNINGS_FILE"

  rebuild_stats

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: recorded learning #$id"
  fi
  echo "{\"id\":$id,\"status\":\"recorded\"}"
}

# ── Command: query ─────────────────────────────────────────
cmd_query() {
  local agent="" type="" limit=5

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) agent="$2"; shift 2 ;;
      --type)  type="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *)       echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$agent" ]]; then
    echo "Error: --agent is required" >&2
    exit 1
  fi

  ensure_file

  local filter
  if [[ -n "$type" ]]; then
    filter="select(.agent == \"$agent\" and .type == \"$type\")"
  else
    filter="select(.agent == \"$agent\")"
  fi

  jq --argjson limit "$limit" \
    "[.learnings[] | $filter] | sort_by(.created) | reverse | .[:$limit]" \
    "$LEARNINGS_FILE"
}

# ── Command: stats ─────────────────────────────────────────
cmd_stats() {
  ensure_file
  rebuild_stats
  jq '.stats' "$LEARNINGS_FILE"
}

# ── Command: prune ─────────────────────────────────────────
cmd_prune() {
  local older_than="90d"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --older-than) older_than="$2"; shift 2 ;;
      *)            echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
  done

  ensure_file

  # Parse duration: Nd → N days
  local days
  days=$(echo "$older_than" | sed 's/d$//')
  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    echo "Error: --older-than must be in format Nd (e.g., 90d)" >&2
    exit 1
  fi

  local cutoff
  if [[ "$(uname)" == "Darwin" ]]; then
    cutoff=$(date -u -v-"${days}d" +%Y-%m-%dT%H:%M:%SZ)
  else
    cutoff=$(date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ)
  fi

  local before_count
  before_count=$(jq '.learnings | length' "$LEARNINGS_FILE")

  local tmp
  tmp=$(jq --arg cutoff "$cutoff" \
    '.learnings = [.learnings[] | select(.created >= $cutoff)]' \
    "$LEARNINGS_FILE")
  echo "$tmp" > "$LEARNINGS_FILE"

  rebuild_stats

  local after_count
  after_count=$(jq '.learnings | length' "$LEARNINGS_FILE")
  local pruned=$((before_count - after_count))

  echo "{\"pruned\":$pruned,\"remaining\":$after_count}"
}

# ── Command: recommend ─────────────────────────────────────
cmd_recommend() {
  ensure_file

  local recommendations="[]"

  # Rule 1: gate-failure type appearing >3 times with same tag → suggest CLAUDE.md rule
  local repeated_failures
  repeated_failures=$(jq '
    [.learnings[] | select(.type == "gate-failure") | .tags // [] | .[]] |
    group_by(.) | map({tag: .[0], count: length}) |
    map(select(.count > 3))
  ' "$LEARNINGS_FILE")

  if [[ "$(echo "$repeated_failures" | jq 'length')" -gt 0 ]]; then
    recommendations=$(echo "$recommendations" | jq --argjson failures "$repeated_failures" \
      '. + [$failures[] | {
        type: "add-rule",
        severity: "high",
        message: ("Gate failure tag \"\(.tag)\" appeared \(.count) times — consider adding to CLAUDE.md rules"),
        data: {tag: .tag, count: .count}
      }]')
  fi

  # Rule 2: agent consistently exceeds time budget (>3 performance learnings mentioning slow)
  local slow_agents
  slow_agents=$(jq '
    [.learnings[] | select(.type == "performance" and (.lesson | test("(?i)slow|exceeded|overtime|long"))) | .agent] |
    group_by(.) | map({agent: .[0], count: length}) |
    map(select(.count > 3))
  ' "$LEARNINGS_FILE")

  if [[ "$(echo "$slow_agents" | jq 'length')" -gt 0 ]]; then
    recommendations=$(echo "$recommendations" | jq --argjson agents "$slow_agents" \
      '. + [$agents[] | {
        type: "model-downgrade",
        severity: "medium",
        message: ("Agent \"\(.agent)\" flagged slow \(.count) times — consider model downgrade or scope reduction"),
        data: {agent: .agent, count: .count}
      }]')
  fi

  # Rule 3: rework rate >20%
  local total_cards
  total_cards=$(jq '[.learnings[].card] | unique | length' "$LEARNINGS_FILE")
  local rework_cards
  rework_cards=$(jq '[.learnings[] | select(.type == "rework-cause") | .card] | unique | length' "$LEARNINGS_FILE")

  if [[ "$total_cards" -gt 0 ]]; then
    local rework_pct=$((rework_cards * 100 / total_cards))
    if [[ "$rework_pct" -gt 20 ]]; then
      local common_rework
      common_rework=$(jq -r '
        [.learnings[] | select(.type == "rework-cause") | .lesson] |
        group_by(.) | map({lesson: .[0], count: length}) |
        sort_by(-.count) | .[0].lesson // "unknown"
      ' "$LEARNINGS_FILE")
      recommendations=$(echo "$recommendations" | jq \
        --argjson pct "$rework_pct" \
        --arg cause "$common_rework" \
        '. + [{
          type: "rework-rate",
          severity: "high",
          message: ("Rework rate is \($pct)% — most common cause: \($cause)"),
          data: {rework_pct: $pct, common_cause: $cause}
        }]')
    fi
  fi

  # Rule 4: specific file/module with repeated failures
  local risky_files
  risky_files=$(jq '
    [.learnings[] | select(.type == "gate-failure" or .type == "pitfall") |
     .tags // [] | .[] | select(test("\\."))] |
    group_by(.) | map({file: .[0], count: length}) |
    map(select(.count > 2)) | sort_by(-.count)
  ' "$LEARNINGS_FILE")

  if [[ "$(echo "$risky_files" | jq 'length')" -gt 0 ]]; then
    recommendations=$(echo "$recommendations" | jq --argjson files "$risky_files" \
      '. + [$files[] | {
        type: "high-risk-file",
        severity: "medium",
        message: ("File/module \"\(.file)\" has \(.count) failures — flag as high-risk"),
        data: {file: .file, count: .count}
      }]')
  fi

  echo "$recommendations" | jq '.'
}

# ── Command: evolve ────────────────────────────────────────
# Cluster similar learnings by lesson text and promote frequent clusters
# into actionable rules with confidence scores.
cmd_evolve() {
  ensure_file

  local min_cluster="${1:-3}"
  local evolved="[]"

  # Group learnings by normalized lesson (lowercase, trimmed)
  # Use tags + type as cluster key for similar lessons
  local clusters
  clusters=$(jq --argjson min "$min_cluster" '
    # Group by type + first tag (coarse clustering)
    [.learnings[] | {
      cluster_key: ((.type) + ":" + ((.tags // [])[0] // "untagged")),
      lesson: .lesson,
      agent: .agent,
      type: .type,
      card: .card,
      tags: (.tags // [])
    }] |
    group_by(.cluster_key) |
    map(select(length >= $min)) |
    map({
      cluster_key: .[0].cluster_key,
      count: length,
      confidence: (if length >= 5 then "high" elif length >= 3 then "medium" else "low" end),
      agents: ([.[].agent] | unique),
      cards: ([.[].card] | unique),
      type: .[0].type,
      tags: ([.[].tags | .[]] | unique),
      representative_lesson: .[0].lesson,
      all_lessons: [.[].lesson] | unique
    }) |
    sort_by(-.count)
  ' "$LEARNINGS_FILE")

  local cluster_count
  cluster_count=$(echo "$clusters" | jq 'length')

  if [[ "$cluster_count" -eq 0 ]]; then
    echo '{"evolved":[],"message":"No clusters found with minimum size '"$min_cluster"'"}'
    return
  fi

  # For each high-confidence cluster, generate a rule suggestion
  local rules
  rules=$(echo "$clusters" | jq '
    [.[] | select(.confidence == "high" or .confidence == "medium") | {
      rule: .representative_lesson,
      confidence: .confidence,
      evidence_count: .count,
      evidence_cards: .cards,
      affected_agents: .agents,
      type: .type,
      tags: .tags,
      action: (
        if .type == "gate-failure" then "Add to CLAUDE.md constraints"
        elif .type == "rework-cause" then "Add to agent instructions"
        elif .type == "pattern" then "Add to best practices"
        elif .type == "pitfall" then "Add to guardrails"
        else "Review and decide"
        end
      )
    }]
  ')

  echo "$rules" | jq --argjson clusters "$clusters" '{
    evolved_rules: .,
    total_clusters: ($clusters | length),
    high_confidence: ([.[] | select(.confidence == "high")] | length),
    medium_confidence: ([.[] | select(.confidence == "medium")] | length)
  }'
}

# ── Dispatch command ───────────────────────────────────────
COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
  echo "Error: command required (record|query|stats|prune|recommend|evolve)" >&2
  exit 1
fi
shift

case "$COMMAND" in
  record)    cmd_record "$@" ;;
  query)     cmd_query "$@" ;;
  stats)     cmd_stats ;;
  prune)     cmd_prune "$@" ;;
  recommend) cmd_recommend ;;
  evolve)    cmd_evolve "${1:-3}" ;;
  *)
    echo "Error: unknown command '$COMMAND'. Use record|query|stats|prune|recommend|evolve" >&2
    exit 1
    ;;
esac
