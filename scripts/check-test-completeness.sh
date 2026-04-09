#!/bin/bash
# check-test-completeness.sh — Verify that every acceptance criterion has a matching test.
#
# Usage:
#   ./check-test-completeness.sh --card 137 --worktree /tmp/helix-wt/feature/137-slug --issue-body "- [ ] Criterion 1\n- [ ] Criterion 2"
#   ./check-test-completeness.sh --card 137 --worktree /tmp/helix-wt/feature/137-slug --issue-body @/tmp/issue-body.txt
#
# Output: JSON with completeness verdict and per-criterion coverage mapping.
#   {
#     "complete": true|false,
#     "card": N,
#     "criteria": [
#       {"criterion": "...", "has_test": true|false, "test_file": "...", "test_name": "..."}
#     ]
#   }
#
# Env:
#   DRY_RUN=1   Return mock complete result without LLM analysis

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
check-test-completeness.sh — Verify acceptance criteria have matching tests.

Usage:
  ./check-test-completeness.sh --card 137 --worktree <path> --issue-body <text-or-@file>

Options:
  --card <N>              Card/issue number (required)
  --worktree <path>       Worktree path (required)
  --issue-body <text>     Issue body text, or @filepath to read from file (required)

Env:
  DRY_RUN=1   Return mock complete result
HELP

# ── Parse args ──────────────────────────────────────────
CARD=""
WORKTREE=""
ISSUE_BODY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)       CARD="$2"; shift 2 ;;
    --worktree)   WORKTREE="$2"; shift 2 ;;
    --issue-body) ISSUE_BODY="$2"; shift 2 ;;
    *)            log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$CARD" ]]; then
  log_error "--card <number> is required"
  exit 1
fi
if [[ -z "$WORKTREE" ]]; then
  log_error "--worktree <path> is required"
  exit 1
fi
if [[ -z "$ISSUE_BODY" ]]; then
  log_error "--issue-body <text-or-@file> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Resolve issue body ──────────────────────────────────
if [[ "$ISSUE_BODY" == @* ]]; then
  BODY_FILE="${ISSUE_BODY#@}"
  if [[ ! -f "$BODY_FILE" ]]; then
    log_error "Issue body file not found: $BODY_FILE"
    exit 1
  fi
  ISSUE_BODY=$(cat "$BODY_FILE")
fi

# ── Extract acceptance criteria ─────────────────────────
# Looks for markdown checklist items: - [ ] or - [x] or * [ ] patterns
extract_criteria() {
  local body="$1"
  echo "$body" | grep -E '^[[:space:]]*[-*][[:space:]]*\[[ x]\][[:space:]]+' | sed -E 's/^[[:space:]]*[-*][[:space:]]*\[[ x]\][[:space:]]+//' || true
}

CRITERIA=$(extract_criteria "$ISSUE_BODY")

if [[ -z "$CRITERIA" ]]; then
  log_warn "No checklist-style acceptance criteria found in issue body"
  jq -n \
    --argjson card "$CARD" \
    '{complete: true, card: $card, criteria: [], note: "No checklist criteria found in issue body"}'
  exit 0
fi

CRITERIA_COUNT=$(echo "$CRITERIA" | wc -l | tr -d ' ')
log_info "Found $CRITERIA_COUNT acceptance criteria for card #$CARD"

# ── DRY_RUN shortcut ───────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  log_info "DRY_RUN=1 — returning mock complete result"
  # Build mock criteria array
  MOCK_CRITERIA="[]"
  while IFS= read -r criterion; do
    [[ -z "$criterion" ]] && continue
    MOCK_CRITERIA=$(echo "$MOCK_CRITERIA" | jq \
      --arg c "$criterion" \
      '. + [{"criterion": $c, "has_test": true, "test_file": "MockTests.swift", "test_name": "testMock"}]')
  done <<< "$CRITERIA"

  jq -n \
    --argjson card "$CARD" \
    --argjson criteria "$MOCK_CRITERIA" \
    '{complete: true, card: $card, criteria: $criteria}'
  exit 0
fi

# ── Collect test files ──────────────────────────────────
TEST_FILES=""
if [[ -d "$WORKTREE/Packages" ]]; then
  TEST_FILES=$(find "$WORKTREE/Packages" -path '*/Tests/*.swift' -type f 2>/dev/null || true)
fi

if [[ -z "$TEST_FILES" ]]; then
  log_warn "No test files found in $WORKTREE/Packages/*/Tests/"
  # All criteria uncovered
  EMPTY_CRITERIA="[]"
  while IFS= read -r criterion; do
    [[ -z "$criterion" ]] && continue
    EMPTY_CRITERIA=$(echo "$EMPTY_CRITERIA" | jq \
      --arg c "$criterion" \
      '. + [{"criterion": $c, "has_test": false, "test_file": null, "test_name": null}]')
  done <<< "$CRITERIA"

  jq -n \
    --argjson card "$CARD" \
    --argjson criteria "$EMPTY_CRITERIA" \
    '{complete: false, card: $card, criteria: $criteria}'
  exit 0
fi

# ── Collect test content ───────────────────────────────
TEST_CONTENT=""
while IFS= read -r tf; do
  [[ -z "$tf" ]] && continue
  # Include relative path header + content
  REL_PATH="${tf#$WORKTREE/}"
  TEST_CONTENT+="
--- $REL_PATH ---
$(cat "$tf")
"
done <<< "$TEST_FILES"

# Truncate if extremely long (keep first 100K chars for LLM context)
if [[ ${#TEST_CONTENT} -gt 100000 ]]; then
  TEST_CONTENT="${TEST_CONTENT:0:100000}
... (truncated)"
fi

# ── Build verification prompt ──────────────────────────
CRITERIA_LIST=""
INDEX=1
while IFS= read -r criterion; do
  [[ -z "$criterion" ]] && continue
  CRITERIA_LIST+="$INDEX. $criterion
"
  INDEX=$((INDEX + 1))
done <<< "$CRITERIA"

PROMPT="You are verifying test completeness for card #$CARD.

## Acceptance Criteria
$CRITERIA_LIST
## Test Files
$TEST_CONTENT
## Task
For each acceptance criterion above, determine whether there is at least one test that validates it.

Respond with ONLY valid JSON (no markdown fences, no explanation):
{
  \"complete\": <true if ALL criteria have tests, false otherwise>,
  \"criteria\": [
    {
      \"criterion\": \"<exact criterion text>\",
      \"has_test\": <true|false>,
      \"test_file\": \"<relative path to test file or null>\",
      \"test_name\": \"<test function name or null>\"
    }
  ]
}"

# ── Output for LLM subagent consumption ────────────────
# The calling agent (Planner) feeds this prompt to a Sonnet subagent.
# We output the prompt and metadata so the caller can invoke the LLM.
jq -n \
  --argjson card "$CARD" \
  --arg prompt "$PROMPT" \
  --argjson criteria_count "$CRITERIA_COUNT" \
  --argjson test_file_count "$(echo "$TEST_FILES" | wc -l | tr -d ' ')" \
  '{
    card: $card,
    llm_gate: true,
    criteria_count: $criteria_count,
    test_file_count: $test_file_count,
    prompt: $prompt,
    instructions: "Feed the prompt to a Sonnet subagent. Parse the JSON response and return it with the card field added."
  }'
