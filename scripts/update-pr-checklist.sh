#!/bin/bash
# update-pr-checklist.sh — Manages acceptance criteria + quality gate checklists on PRs.
#
# Usage:
#   ./update-pr-checklist.sh --pr 42 --card 137
#   ./update-pr-checklist.sh --pr 42 --card 137 --check "Add journal entry detail view"
#   ./update-pr-checklist.sh --pr 42 --card 137 --check-gate "Build passes"
#
# Env:
#   DRY_RUN=1   Skip gh calls, print what would happen
#
# Output: JSON { all_checked, total, checked, unchecked: [...] }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
update-pr-checklist.sh — Manages acceptance criteria + quality gate checklists on PRs.

Usage:
  ./update-pr-checklist.sh --pr 42 --card 137
  ./update-pr-checklist.sh --pr 42 --card 137 --check "Add journal entry detail view"
  ./update-pr-checklist.sh --pr 42 --card 137 --check-gate "Build passes"

Options:
  --pr <N>             PR number (required)
  --card <N>           Card/issue number (required)
  --check "<text>"     Check off a specific acceptance criterion
  --check-gate "<name>" Check off a quality gate checkbox

Env:
  DRY_RUN=1            Skip gh calls, print what would happen
HELP

# ── Parse args ──────────────────────────────────────────
PR_NUMBER=""
CARD=""
CHECK_CRITERION=""
CHECK_GATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)         PR_NUMBER="$2"; shift 2 ;;
    --card)       CARD="$2"; shift 2 ;;
    --check)      CHECK_CRITERION="$2"; shift 2 ;;
    --check-gate) CHECK_GATE="$2"; shift 2 ;;
    *)            log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  log_error "--pr <number> is required"
  exit 1
fi
if [[ -z "$CARD" ]]; then
  log_error "--card <number> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Quality gate template ──────────────────────────────
QUALITY_GATES=(
  "Builder gates passing (build, tests, lint, static analysis)"
  "Code review: 0 P0/P1"
  "Visual QA pass (if UI)"
  "TestFlight build uploaded (if UI)"
)

# ── Fetch issue acceptance criteria ────────────────────
fetch_issue_body() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "${MOCK_ISSUE_BODY:-}"
    return
  fi
  gh issue view "$CARD" --repo "$REPO" --json body -q '.body' 2>/dev/null || echo ""
}

extract_acceptance_criteria() {
  local body="$1"
  # Extract lines matching "- [ ] ..." or "- [x] ..." patterns
  echo "$body" | grep -E '^\s*-\s*\[[ xX]\]\s+' | sed 's/^\s*//' || true
}

# ── Fetch current PR body ──────────────────────────────
fetch_pr_body() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "${MOCK_PR_BODY:-}"
    return
  fi
  gh pr view "$PR_NUMBER" --repo "$REPO" --json body -q '.body' 2>/dev/null || echo ""
}

# ── Check if section exists in body ────────────────────
has_section() {
  local body="$1"
  local heading="$2"
  echo "$body" | grep -qF "## $heading"
}

# ── Build acceptance criteria section ──────────────────
build_acceptance_section() {
  local criteria_lines="$1"
  if [[ -z "$criteria_lines" ]]; then
    return
  fi
  echo ""
  echo "## Acceptance Criteria"
  # Reset all to unchecked when first adding
  echo "$criteria_lines" | sed 's/- \[[xX]\]/- [ ]/'
}

# ── Build quality gates section ────────────────────────
build_quality_gates_section() {
  echo ""
  echo "## Quality Gates"
  for gate in "${QUALITY_GATES[@]}"; do
    echo "- [ ] $gate"
  done
}

# ── Normalize text for fuzzy matching ─────────────────
normalize_text() {
  # Lowercase, strip leading/trailing whitespace, remove markdown formatting
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/[*_`~]//g' | sed 's/[[:space:]]\{2,\}/ /g'
}

# ── Check off a criterion in body text (fuzzy match) ──
check_criterion_in_body() {
  local body="$1"
  local criterion="$2"
  local norm_criterion
  norm_criterion=$(normalize_text "$criterion")

  local match_count=0
  local first_match_line=""

  # Find matching checkbox lines via fuzzy substring match
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Extract text after the checkbox
    local line_text
    line_text=$(echo "$line" | sed 's/^[[:space:]]*- \[[ xX]\] //')
    local norm_line
    norm_line=$(normalize_text "$line_text")

    # Match if normalized criterion is substring of line text, or vice versa
    if [[ "$norm_line" == *"$norm_criterion"* ]] || [[ "$norm_criterion" == *"$norm_line"* ]]; then
      match_count=$((match_count + 1))
      if [[ $match_count -eq 1 ]]; then
        first_match_line="$line_text"
      fi
    fi
  done < <(echo "$body" | grep -E '^\s*-\s*\[ \]\s+' || true)

  if [[ $match_count -eq 0 ]]; then
    # No fuzzy match found — return body unchanged
    echo "$body"
    return
  fi

  if [[ $match_count -gt 1 ]]; then
    log_warn "Fuzzy match ambiguity: '$criterion' matched $match_count checkboxes — checking first match: '$first_match_line'"
  fi

  # Check off the first match using python for reliable string replacement
  python3 -c "
import sys
body = sys.stdin.read()
old = '- [ ] ' + sys.argv[1]
new = '- [x] ' + sys.argv[1]
print(body.replace(old, new, 1), end='')
" "$first_match_line" <<< "$body"
}

# ── Main logic ─────────────────────────────────────────

# Fetch current state
ISSUE_BODY="$(fetch_issue_body)"
PR_BODY="$(fetch_pr_body)"

# Extract acceptance criteria from issue
CRITERIA="$(extract_acceptance_criteria "$ISSUE_BODY")"

# Initialize: add Acceptance Criteria section if missing
if ! has_section "$PR_BODY" "Acceptance Criteria"; then
  if [[ -n "$CRITERIA" ]]; then
    ACCEPTANCE_SECTION="$(build_acceptance_section "$CRITERIA")"
    PR_BODY="${PR_BODY}${ACCEPTANCE_SECTION}"
    log_info "Added Acceptance Criteria section with $(echo "$CRITERIA" | wc -l | tr -d ' ') items"
  fi
fi

# Initialize: add Quality Gates section if missing
if ! has_section "$PR_BODY" "Quality Gates"; then
  GATES_SECTION="$(build_quality_gates_section)"
  PR_BODY="${PR_BODY}${GATES_SECTION}"
  log_info "Added Quality Gates section with ${#QUALITY_GATES[@]} items"
fi

# Check off a specific criterion
if [[ -n "$CHECK_CRITERION" ]]; then
  PR_BODY="$(check_criterion_in_body "$PR_BODY" "$CHECK_CRITERION")"
  log_info "Checked off criterion: $CHECK_CRITERION"
fi

# Check off a specific quality gate
if [[ -n "$CHECK_GATE" ]]; then
  PR_BODY="$(check_criterion_in_body "$PR_BODY" "$CHECK_GATE")"
  log_info "Checked off gate: $CHECK_GATE"
fi

# ── Update PR body ─────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  log_info "[DRY_RUN] Would update PR #$PR_NUMBER body"
  log_info "[DRY_RUN] New body:"
  echo "$PR_BODY" >&2
else
  gh pr edit "$PR_NUMBER" --repo "$REPO" --body "$PR_BODY"
  log_info "Updated PR #$PR_NUMBER body"
fi

# ── Count checkboxes and produce JSON output ───────────
TOTAL=0
CHECKED=0
UNCHECKED_LIST="[]"

while IFS= read -r line; do
  if [[ -z "$line" ]]; then continue; fi
  TOTAL=$((TOTAL + 1))
  # Extract the text after the checkbox
  local_text=$(echo "$line" | sed 's/^- \[[ xX]\] //')
  if echo "$line" | grep -qE '^\s*-\s*\[[xX]\]'; then
    CHECKED=$((CHECKED + 1))
  else
    UNCHECKED_LIST=$(echo "$UNCHECKED_LIST" | jq --arg t "$local_text" '. + [$t]')
  fi
done < <(echo "$PR_BODY" | grep -E '^\s*-\s*\[[ xX]\]\s+' || true)

ALL_CHECKED=false
if [[ $TOTAL -gt 0 && $CHECKED -eq $TOTAL ]]; then
  ALL_CHECKED=true
fi

jq -n \
  --argjson all_checked "$ALL_CHECKED" \
  --argjson total "$TOTAL" \
  --argjson checked "$CHECKED" \
  --argjson unchecked "$UNCHECKED_LIST" \
  '{
    all_checked: $all_checked,
    total: $total,
    checked: $checked,
    unchecked: $unchecked
  }'
