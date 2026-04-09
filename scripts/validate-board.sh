#!/bin/bash
# validate-board.sh — Validate GitHub Project board schema on startup.
# Checks that expected columns and custom fields exist before dispatch.
#
# Usage:
#   ./validate-board.sh           # Full validation
#   ./validate-board.sh --quiet   # Exit code only (0=ok, 1=issues found)
#
# Requires: gh CLI with project scopes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
validate-board.sh — Validate GitHub Project board schema.

Checks:
  1. Project exists and is accessible
  2. Required Status column options exist (Backlog, Ready, In Progress, In Review, Done)
  3. Required custom fields exist (HasUIChanges, DesignURL, Branch, PR URL, etc.)
  4. Field IDs in config.sh match the live project

Usage:
  ./validate-board.sh           # Full validation with details
  ./validate-board.sh --quiet   # Exit code only
HELP

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

ERRORS=()
WARNINGS=()

log_check() {
  [[ "$QUIET" == "false" ]] && echo "  ✓ $1"
}

log_fail() {
  ERRORS+=("$1")
  [[ "$QUIET" == "false" ]] && echo "  ✗ $1" >&2
}

log_warning() {
  WARNINGS+=("$1")
  [[ "$QUIET" == "false" ]] && echo "  ⚠ $1" >&2
}

# ── Step 1: Read board ────────────────────────────────────
[[ "$QUIET" == "false" ]] && echo "Validating board schema..."

BOARD_JSON=$(bash "$SCRIPTS_DIR/read-board.sh" --no-cache 2>/dev/null) || {
  log_fail "Cannot read board — check gh auth and project scopes"
  echo "Run: gh auth refresh -h github.com -s read:project -s project"
  exit 1
}

# ── Step 2: Check Status column options ───────────────────
REQUIRED_COLUMNS=("Backlog" "Ready" "In Progress" "In Review" "Done")

STATUS_FIELD=$(echo "$BOARD_JSON" | jq '[.fields[] | select(.name == "Status")] | .[0]')
if [[ -z "$STATUS_FIELD" || "$STATUS_FIELD" == "null" ]]; then
  log_fail "Status field not found on project board"
else
  AVAILABLE_OPTIONS=$(echo "$STATUS_FIELD" | jq -r '[.options[].name] | join(", ")')
  for col in "${REQUIRED_COLUMNS[@]}"; do
    if echo "$STATUS_FIELD" | jq -e --arg c "$col" '.options | any(.name == $c)' >/dev/null 2>&1; then
      log_check "Column: $col"
    else
      # Case-insensitive fallback check
      if echo "$STATUS_FIELD" | jq -e --arg c "$col" '.options | any(.name | ascii_downcase == ($c | ascii_downcase))' >/dev/null 2>&1; then
        log_warning "Column '$col' found with different casing — dispatcher may break"
      else
        log_fail "Missing column: $col (available: $AVAILABLE_OPTIONS)"
      fi
    fi
  done
fi

# ── Step 3: Check required custom fields ─────────────────
REQUIRED_FIELDS=(
  "Status"
  "Priority"
  "Branch"
  "PR URL"
  "HasUIChanges"
  "Phase"
  "OwnerAgent"
  "LoopCount"
  "MergeStatus"
)

OPTIONAL_FIELDS=(
  "DesignURL"
  "EvidenceURL"
  "ValidationReport"
  "Risk"
  "ReworkReason"
  "BlockedReason"
  "ApprovalStatus"
  "AgentCost"
  "BlockedBy"
  "Size"
)

for field in "${REQUIRED_FIELDS[@]}"; do
  if echo "$BOARD_JSON" | jq -e --arg f "$field" '.fields | any(.name == $f)' >/dev/null 2>&1; then
    log_check "Field: $field"
  else
    log_fail "Missing required field: $field"
  fi
done

for field in "${OPTIONAL_FIELDS[@]}"; do
  if echo "$BOARD_JSON" | jq -e --arg f "$field" '.fields | any(.name == $f)' >/dev/null 2>&1; then
    log_check "Field: $field (optional)"
  else
    log_warning "Missing optional field: $field"
  fi
done

# ── Step 4: Validate field IDs match live project ────────
[[ "$QUIET" == "false" ]] && echo ""
[[ "$QUIET" == "false" ]] && echo "Validating field IDs..."

validate_field_id() {
  local config_id="$1" field_name="$2"
  local live_id
  live_id=$(echo "$BOARD_JSON" | jq -r --arg f "$field_name" '[.fields[] | select(.name == $f) | .id] | .[0] // ""')
  if [[ -z "$live_id" ]]; then
    return  # Field doesn't exist, already reported above
  fi
  if [[ "$config_id" == "$live_id" ]]; then
    log_check "ID match: $field_name"
  else
    log_fail "ID mismatch for $field_name: config=$config_id live=$live_id"
  fi
}

validate_field_id "$FIELD_ID_STATUS" "Status"
validate_field_id "$FIELD_ID_PRIORITY" "Priority"
validate_field_id "$FIELD_ID_BRANCH" "Branch"
validate_field_id "$FIELD_ID_PR_URL" "PR URL"
validate_field_id "$FIELD_ID_HAS_UI_CHANGES" "HasUIChanges"

# ── Summary ───────────────────────────────────────────────
[[ "$QUIET" == "false" ]] && echo ""

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  [[ "$QUIET" == "false" ]] && echo "FAIL: ${#ERRORS[@]} error(s), ${#WARNINGS[@]} warning(s)"
  exit 1
elif [[ ${#WARNINGS[@]} -gt 0 ]]; then
  [[ "$QUIET" == "false" ]] && echo "WARN: ${#WARNINGS[@]} warning(s), 0 errors"
  exit 0
else
  [[ "$QUIET" == "false" ]] && echo "OK: Board schema valid"
  exit 0
fi
