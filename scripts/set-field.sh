#!/bin/bash
# set-field.sh — Set a custom field value on a project card.
#
# Usage:
#   ./set-field.sh --issue 42 --field "Branch" --value "feature/42-journal-export"
#   ./set-field.sh --item-id <ID> --field "LoopCount" --value 2 --type number
#   ./set-field.sh --issue 42 --field "Priority" --value "P1" --type select
#
# Field types:
#   text (default) — free text fields like Branch, ReworkReason, DesignURL
#   number         — numeric fields like LoopCount
#   select         — single-select fields like Priority, Severity, BlastRadius
#
# Requires: gh CLI with project scopes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
set-field.sh — Set a custom field value on a project card.

Usage:
  ./set-field.sh --issue 42 --field "Branch" --value "feature/42-journal-export"
  ./set-field.sh --item-id <ID> --field "LoopCount" --value 2 --type number
  ./set-field.sh --issue 42 --field "Priority" --value "P1" --type select

Field types:
  text (default) — free text fields like Branch, ReworkReason, DesignURL
  number         — numeric fields like LoopCount
  select         — single-select fields like Priority, Severity, BlastRadius

Requires: gh CLI with project scopes
  gh auth refresh -h github.com -s read:project -s project
HELP

PROJECT_NUMBER=""
ITEM_ID=""
ISSUE_NUMBER=""
FIELD_NAME=""
FIELD_VALUE=""
FIELD_TYPE="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --item-id)          ITEM_ID="$2"; shift 2 ;;
    --issue)            ISSUE_NUMBER="$2"; shift 2 ;;
    --field)            FIELD_NAME="$2"; shift 2 ;;
    --value)            FIELD_VALUE="$2"; shift 2 ;;
    --type)             FIELD_TYPE="$2"; shift 2 ;;
    --project-number)   PROJECT_NUMBER="$2"; shift 2 ;;
    *)                  echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$FIELD_NAME" || -z "$FIELD_VALUE" ]]; then
  echo "Error: --field and --value are required" >&2
  exit 1
fi

# Resolve item ID from issue number if needed (uses cache)
if [[ -z "$ITEM_ID" && -n "$ISSUE_NUMBER" ]]; then
  BOARD_JSON=$("$SCRIPT_DIR/read-board.sh" ${PROJECT_NUMBER:+--project-number "$PROJECT_NUMBER"} --card-id "$ISSUE_NUMBER")
  ITEM_ID=$(echo "$BOARD_JSON" | jq -r '.cards[0].item_id // empty')
  PROJECT_NUMBER=$(echo "$BOARD_JSON" | jq -r '.project.number')

  if [[ -z "$ITEM_ID" ]]; then
    echo "Error: Issue #$ISSUE_NUMBER not found on the project board" >&2
    exit 1
  fi
fi

if [[ -z "$ITEM_ID" ]]; then
  echo "Error: Either --item-id or --issue is required" >&2
  exit 1
fi

# Auto-discover project number
if [[ -z "$PROJECT_NUMBER" ]]; then
  PROJECT_NUMBER=$(gh project list --owner "$OWNER" --format json | jq -r '.projects[0].number // empty')
fi

# Get project global ID
PROJECT_ID=$(gh api graphql -f query='
  query($owner: String!, $number: Int!) {
    user(login: $owner) {
      projectV2(number: $number) {
        id
      }
    }
  }
' -f owner="$OWNER" -F number="$PROJECT_NUMBER" --jq '.data.user.projectV2.id')

# Get the field ID
FIELD_DATA=$(gh api graphql -f query='
  query($projectId: ID!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        fields(first: 30) {
          nodes {
            ... on ProjectV2FieldCommon { id name }
            ... on ProjectV2SingleSelectField { id name options { id name } }
          }
        }
      }
    }
  }
' -f projectId="$PROJECT_ID")

FIELD_ID=$(echo "$FIELD_DATA" | jq -r --arg name "$FIELD_NAME" '.data.node.fields.nodes[] | select(.name == $name) | .id')

if [[ -z "$FIELD_ID" || "$FIELD_ID" == "null" ]]; then
  # Fallback: check config.sh for known field IDs before failing
  source "$SCRIPT_DIR/config.sh" 2>/dev/null || true
  case "$FIELD_NAME" in
    HasUIChanges)  FIELD_ID="${FIELD_ID_HAS_UI_CHANGES:-}" ;;
    DesignURL)     FIELD_ID="${FIELD_ID_DESIGN_URL:-}" ;;
    Branch)        FIELD_ID="${FIELD_ID_BRANCH:-}" ;;
    "PR URL")      FIELD_ID="${FIELD_ID_PR_URL:-}" ;;
    LoopCount)     FIELD_ID="${FIELD_ID_LOOP_COUNT:-}" ;;
    BlockedReason) FIELD_ID="${FIELD_ID_BLOCKED_REASON:-}" ;;
    ReworkReason)  FIELD_ID="${FIELD_ID_REWORK_REASON:-}" ;;
  esac
  if [[ -z "$FIELD_ID" || "$FIELD_ID" == "null" ]]; then
    echo "Error: Field '$FIELD_NAME' not found on project. Available fields:" >&2
    echo "$FIELD_DATA" | jq -r '.data.node.fields.nodes[] | select(.name != null) | .name' >&2
    exit 1
  fi
fi

# Build the value payload based on type
case "$FIELD_TYPE" in
  text)
    MUTATION_VALUE="text: $(echo "$FIELD_VALUE" | jq -Rs '.')"
    ;;
  number)
    MUTATION_VALUE="number: $FIELD_VALUE"
    ;;
  select)
    OPTION_ID=$(echo "$FIELD_DATA" | jq -r --arg name "$FIELD_NAME" --arg val "$FIELD_VALUE" \
      '.data.node.fields.nodes[] | select(.name == $name) | .options[] | select(.name == $val) | .id')
    if [[ -z "$OPTION_ID" || "$OPTION_ID" == "null" ]]; then
      # Fallback: fetch options directly using the field ID
      if [[ -n "$FIELD_ID" ]]; then
        OPTION_ID=$(gh api graphql -f query='
          query($fieldId: ID!) {
            node(id: $fieldId) {
              ... on ProjectV2SingleSelectField { options { id name } }
            }
          }
        ' -f fieldId="$FIELD_ID" --jq ".data.node.options[] | select(.name == \"$FIELD_VALUE\") | .id" 2>/dev/null || echo "")
      fi
      if [[ -z "$OPTION_ID" || "$OPTION_ID" == "null" ]]; then
        echo "Error: Option '$FIELD_VALUE' not found for field '$FIELD_NAME'." >&2
        exit 1
      fi
    fi
    MUTATION_VALUE="singleSelectOptionId: \"$OPTION_ID\""
    ;;
  *)
    echo "Error: Unknown field type '$FIELD_TYPE'. Use: text, number, select" >&2
    exit 1
    ;;
esac

# Update the field using inline mutation
gh api graphql -f query="
  mutation {
    updateProjectV2ItemFieldValue(input: {
      projectId: \"$PROJECT_ID\"
      itemId: \"$ITEM_ID\"
      fieldId: \"$FIELD_ID\"
      value: {$MUTATION_VALUE}
    }) {
      projectV2Item { id }
    }
  }
" > /dev/null

# Invalidate cache after write
rm -f "$BOARD_CACHE_FILE" 2>/dev/null

echo "Set $FIELD_NAME=$FIELD_VALUE on item" >&2
