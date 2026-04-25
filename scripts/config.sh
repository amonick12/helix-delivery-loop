#!/bin/bash
# config.sh — Shared constants for the delivery loop.
# Source this from every script: source "$SCRIPT_DIR/config.sh"

# ── Project ──────────────────────────────────────────────
OWNER="amonick12"
REPO="amonick12/helix"       # Full owner/repo for gh commands
REPO_NAME="helix"            # Just the repo name for API paths
PROJECT_NUMBER=3
PROJECT_ID="PVT_kwHOADV6sM4BR2BF"
BASE_BRANCH="autodev"

# ── Paths ────────────────────────────────────────────────
# HELIX_REPO_ROOT is the canonical "iOS app repo root" for any script that
# needs to read or modify shipping code, mockups, .claude state, the
# screenshots release, etc. ALWAYS use this for those purposes.
HELIX_REPO_ROOT="${HELIX_REPO_ROOT:-/Users/aaronmonick/Downloads/helix}"
# REPO_ROOT is kept as an alias so older scripts that haven't migrated yet
# continue to work. New code should always use HELIX_REPO_ROOT explicitly.
REPO_ROOT="$HELIX_REPO_ROOT"
# Plugin dir resolves relative to this script (the cache), not the repo.
# This makes the cache the single source of truth for all plugin files.
PLUGIN_DIR="$(cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." && pwd)"
SCRIPTS_DIR="$PLUGIN_DIR/scripts"
REFS_DIR="$PLUGIN_DIR/references"
STATE_FILE="${STATE_FILE:-$REPO_ROOT/.claude/delivery-loop-state.json}"
WORKTREE_BASE="/tmp/helix-wt/feature"
BOARD_CACHE_FILE="/tmp/helix-board-cache.json"
BOARD_CACHE_TTL=60
USAGE_DIR="${USAGE_DIR:-$REPO_ROOT/.claude/delivery-loop-usage}"

# ── Board Field IDs ──────────────────────────────────────
FIELD_ID_STATUS="PVTSSF_lAHOADV6sM4BR2BFzg_jRLM"
FIELD_ID_PRIORITY="PVTSSF_lAHOADV6sM4BR2BFzg_jRLs"
FIELD_ID_SIZE="PVTSSF_lAHOADV6sM4BR2BFzg_jRLw"
FIELD_ID_DESIGN_URL="PVTF_lAHOADV6sM4BR2BFzhABC_A"
FIELD_ID_BRANCH="PVTF_lAHOADV6sM4BR2BFzg_jRQU"
FIELD_ID_PR_URL="PVTF_lAHOADV6sM4BR2BFzg_jRQY"
FIELD_ID_EVIDENCE_URL="PVTF_lAHOADV6sM4BR2BFzg_jRQc"
FIELD_ID_VALIDATION_REPORT="PVTF_lAHOADV6sM4BR2BFzg_jRQg"
FIELD_ID_RISK="PVTF_lAHOADV6sM4BR2BFzg_jRQk"
FIELD_ID_REWORK_REASON="PVTF_lAHOADV6sM4BR2BFzg_jRQo"
FIELD_ID_BLOCKED_REASON="PVTF_lAHOADV6sM4BR2BFzg_jRQs"
FIELD_ID_PHASE="PVTF_lAHOADV6sM4BR2BFzg_jRPk"
FIELD_ID_OWNER_AGENT="PVTF_lAHOADV6sM4BR2BFzg_jRQQ"
FIELD_ID_LOOP_COUNT="PVTF_lAHOADV6sM4BR2BFzg_jRRo"
FIELD_ID_MERGE_STATUS="PVTF_lAHOADV6sM4BR2BFzg_jRRk"
FIELD_ID_APPROVAL_STATUS="PVTF_lAHOADV6sM4BR2BFzg_jRQ4"

# ── New Fields (created by Task 13) ─────────────────────
FIELD_ID_AGENT_COST="PVTF_lAHOADV6sM4BR2BFzhAcE-c"
FIELD_ID_BLOCKED_BY="PVTF_lAHOADV6sM4BR2BFzhAcE-g"
FIELD_ID_HAS_UI_CHANGES="PVTF_lAHOADV6sM4BR2BFzhAcE-k"

# ── Status Column Option IDs ────────────────────────────
STATUS_BACKLOG="4822d479"
STATUS_READY="b4496ee1"
STATUS_IN_PROGRESS="76cc1122"
STATUS_IN_REVIEW="4d98a602"
STATUS_DONE="42107418"

# ── WIP Limits ───────────────────────────────────────────
WIP_IN_PROGRESS=4
WIP_IN_REVIEW=5

# ── Model Assignment ─────────────────────────────────────
MODEL_SCOUT="sonnet"
MODEL_DESIGNER="opus"
MODEL_PLANNER="opus"
MODEL_BUILDER="opus"
MODEL_BUILDER_REWORK="opus"
MODEL_MAINTAINER="opus"
MODEL_REVIEWER="haiku"
MODEL_TESTER="sonnet"
MODEL_RELEASER="haiku"

# ── Cost Rates (per 1M tokens, USD) ─────────────────────
COST_INPUT_OPUS=15.00
COST_OUTPUT_OPUS=75.00
COST_INPUT_SONNET=3.00
COST_OUTPUT_SONNET=15.00
COST_INPUT_HAIKU=0.80
COST_OUTPUT_HAIKU=4.00

# ── Agent Classification ────────────────────────────────
# Simulator agents need the device for screenshots, UITests, or TestFlight.
# Non-simulator agents (Designer, Planner, Builder) can run in parallel.
# Builder only uses xcodebuild build + unit tests on macOS destination.
SIMULATOR_AGENTS="scout designer tester releaser"
NON_SIMULATOR_AGENTS="planner builder reviewer maintainer"

needs_simulator() {
  local agent="$1"
  case "$agent" in
    scout|designer|tester|releaser) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Simulator ────────────────────────────────────────────
SIMULATOR_UDID="$(xcrun simctl list devices available 2>/dev/null | grep 'iPhone 17 Pro (Codex)' | grep -oE '[A-F0-9-]{36}' | head -1)"
if [[ -z "$SIMULATOR_UDID" ]]; then
  log_warn "iPhone 17 Pro (Codex) simulator not found — run: xcrun simctl create 'iPhone 17 Pro (Codex)' 'iPhone 17 Pro' 'iOS-26-2'"
fi
SIMULATOR_NAME="iPhone 17 Pro (Codex)"
SIMULATOR_LOCK="/tmp/helix-simulator.lock"

# ── Mockups (SwiftUI) ────────────────────────────────────
# Designer agent writes SwiftUI mockup views into MOCKUP_DIR using real Helix
# design tokens, registers them in MOCKUP_REGISTRY_FILE, builds, boots the
# sim with MOCKUP_FIXTURE_ENV set to a panel id, screenshots, uploads.
MOCKUP_DIR="$HELIX_REPO_ROOT/helix-app/PreviewHost/Mockups"
MOCKUP_REGISTRY_FILE="$HELIX_REPO_ROOT/helix-app/PreviewHost/Mockups/EpicMockupRegistry.swift"
MOCKUP_FIXTURE_ENV="MOCKUP_FIXTURE"
MOCKUP_BUILD_SCRIPT="$HELIX_REPO_ROOT/devtools/ios-agent/build.sh"
MOCKUP_LAUNCH_SCRIPT="$HELIX_REPO_ROOT/devtools/ios-agent/launch-app.sh"
MOCKUP_SCREENSHOT_SCRIPT="$HELIX_REPO_ROOT/devtools/ios-agent/screenshot.sh"

# ── Agent Comment Filter ─────────────────────────────────
# Regex pattern to identify agent-posted PR comments (not user comments)
# Used by dispatcher.sh and check-pr-comments.sh to avoid re-triggering on our own comments
AGENT_COMMENT_FILTER="^bot:|Verification Report|Validation Report|Gate Results|TestFlight Build|Visual QA|Simulator Visual Evidence|Simulator UI Gates|Quality Gates|Cost Breakdown|Agent Cost|Screen Recording|Code [Rr]eview|Design [Ff]idelity|Visual Evidence|Acceptance Criteria|Builder Gates|Builder handoff|Rework —|Evidence gap"

# ── PR Comment Upsert ────────────────────────────────────
# Post or update a PR comment. Finds existing by heading prefix, patches it, or creates new.
# Usage: upsert_pr_comment <pr_number> <heading_prefix> <body>
upsert_pr_comment() {
  local pr="$1" prefix="$2" body="$3"
  local existing_id
  existing_id=$(gh pr view "$pr" --repo "$REPO" --json comments \
    --jq "[.comments[] | select(.body | startswith(\"$prefix\")) | .databaseId] | last // empty" 2>/dev/null)
  if [[ -n "$existing_id" ]]; then
    gh api "repos/${REPO}/issues/comments/${existing_id}" -X PATCH -f body="$body" 2>/dev/null || \
      gh pr comment "$pr" --repo "$REPO" --body "$body" 2>/dev/null
  else
    gh pr comment "$pr" --repo "$REPO" --body "$body" 2>/dev/null
  fi
}

# ── Build Numbers ────────────────────────────────────────
build_number() {
  local issue=$1
  local loop_count=${2:-0}
  echo $(( issue * 100 + loop_count ))
}

# ── Simulator Lock ───────────────────────────────────────
acquire_simulator_lock() {
  local timeout=${1:-300}
  local start=$(date +%s)
  while ! mkdir "$SIMULATOR_LOCK" 2>/dev/null; do
    local now=$(date +%s)
    if (( now - start > timeout )); then
      log_error "Simulator lock timeout after ${timeout}s"
      local pid_file="$SIMULATOR_LOCK/pid"
      if [[ -f "$pid_file" ]]; then
        local lock_pid=$(cat "$pid_file")
        if ! kill -0 "$lock_pid" 2>/dev/null; then
          log_warn "Stale lock from dead process $lock_pid — removing"
          rm -rf "$SIMULATOR_LOCK"
          continue
        fi
      fi
      return 1
    fi
    sleep 2
  done
  echo $$ > "$SIMULATOR_LOCK/pid"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SIMULATOR_LOCK/acquired"
  ensure_single_simulator
  ensure_single_xcodebuild
  log_info "Simulator lock acquired (PID $$)"
}

release_simulator_lock() {
  rm -rf "$SIMULATOR_LOCK"
  log_info "Simulator lock released"
}

ensure_single_simulator() {
  local booted
  booted=$(xcrun simctl list devices booted 2>/dev/null | grep -c "Booted" || echo 0)
  if [[ "$booted" -gt 1 ]]; then
    log_warn "Multiple simulators booted ($booted) — shutting down extras"
    xcrun simctl shutdown all 2>/dev/null
    xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null
  fi
}

# ── Xcodebuild Guard ────────────────────────────────────
ensure_single_xcodebuild() {
  local existing_pids
  existing_pids=$(pgrep -f "xcodebuild" 2>/dev/null || true)
  if [[ -n "$existing_pids" ]]; then
    log_warn "Killing stale xcodebuild processes: $existing_pids"
    pkill -f "xcodebuild" 2>/dev/null || true
    local waited=0
    while pgrep -f "xcodebuild" >/dev/null 2>&1 && [[ $waited -lt 5 ]]; do
      sleep 1
      waited=$((waited + 1))
    done
    if pgrep -f "xcodebuild" >/dev/null 2>&1; then
      log_warn "Force-killing remaining xcodebuild processes"
      pkill -9 -f "xcodebuild" 2>/dev/null || true
    fi
  fi
}

# ── Artifact Directory ──────────────────────────────────
ARTIFACT_BASE="/tmp/helix-artifacts"

ensure_artifact_dir() {
  local card="$1"
  local dir="$ARTIFACT_BASE/$card"
  mkdir -p "$dir"
  echo "$dir"
}

# Standard artifact file names per card
ARTIFACT_SPEC="spec.md"
ARTIFACT_PLAN="plan.md"
ARTIFACT_TEST_RESULTS="test-results.json"
ARTIFACT_VERIFICATION="verification.json"
ARTIFACT_DESIGN="design.md"

# ── Helpers ──────────────────────────────────────────────
show_help_if_requested() {
  for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
      cat
      exit 0
    fi
  done
  cat > /dev/null
}

log_info()  { echo "[INFO]  $(date +%H:%M:%S) $*" >&2; }
log_warn()  { echo "[WARN]  $(date +%H:%M:%S) $*" >&2; }
log_error() { echo "[ERROR] $(date +%H:%M:%S) $*" >&2; }

# ── gh API retry wrapper ────────────────────────────────
# Wraps any gh CLI invocation with exponential backoff on retryable errors:
# rate limits (HTTP 429, 403 with 'rate limit'), transient network failures
# (connection refused, EOF, gateway). Non-retryable errors return immediately
# with the original exit code. Used by scripts that hit gh in tight loops.
gh_retry() {
  local max_attempts=3
  local backoff=2
  local attempt=1
  local stderr_file
  stderr_file=$(mktemp)
  local rc=0
  while (( attempt <= max_attempts )); do
    "$@" 2>"$stderr_file"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
      cat "$stderr_file" >&2
      rm -f "$stderr_file"
      return 0
    fi
    local err
    err=$(cat "$stderr_file")
    # Decide whether to retry. Pattern list covers GitHub's flaky modes.
    if echo "$err" | grep -qiE 'rate limit|429|403.*rate|connection refused|gateway timeout|EOF|temporary failure'; then
      log_warn "gh transient error (attempt $attempt/$max_attempts): $(echo "$err" | head -1)"
      sleep "$backoff"
      backoff=$(( backoff * 2 ))
      attempt=$(( attempt + 1 ))
      continue
    fi
    # Non-retryable — surface stderr and exit
    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    return "$rc"
  done
  cat "$stderr_file" >&2
  rm -f "$stderr_file"
  return "$rc"
}
