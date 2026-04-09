#!/bin/bash
# move-card.sh — Move a card to a different column on the GitHub Project board.
#
# Usage:
#   ./move-card.sh --item-id <PROJECT_ITEM_ID> --to "In Progress"
#   ./move-card.sh --issue 42 --to "In Review"
#   ./move-card.sh --issue 42 --to "In Review" --project-number 5
#
# Requires: gh CLI with project scopes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
move-card.sh — Move a card to a different column on the GitHub Project board.

Usage:
  ./move-card.sh --item-id <PROJECT_ITEM_ID> --to "In Progress"
  ./move-card.sh --issue 42 --to "In Review"
  ./move-card.sh --issue 42 --to "In Review" --project-number 5

Valid columns: Backlog, Design, Ready, In Progress, In Review, Done

Requires: gh CLI with project scopes
  gh auth refresh -h github.com -s read:project -s project
HELP

PROJECT_NUMBER=""
ITEM_ID=""
ISSUE_NUMBER=""
TARGET_COLUMN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --item-id)          ITEM_ID="$2"; shift 2 ;;
    --issue)            ISSUE_NUMBER="$2"; shift 2 ;;
    --to)               TARGET_COLUMN="$2"; shift 2 ;;
    --project-number)   PROJECT_NUMBER="$2"; shift 2 ;;
    *)                  echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TARGET_COLUMN" ]]; then
  echo "Error: --to <column> is required" >&2
  echo "Valid columns: Backlog, Design, Ready, In Progress, In Review, Done" >&2
  exit 1
fi

# If we have an issue number but no item ID, look it up (uses cache)
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

# Auto-discover project number if not provided
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

# Get the Status field ID and target option ID
FIELD_DATA=$(gh api graphql -f query='
  query($projectId: ID!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        fields(first: 30) {
          nodes {
            ... on ProjectV2SingleSelectField {
              id
              name
              options { id name }
            }
          }
        }
      }
    }
  }
' -f projectId="$PROJECT_ID")

STATUS_FIELD_ID=$(echo "$FIELD_DATA" | jq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id')
OPTION_ID=$(echo "$FIELD_DATA" | jq -r --arg col "$TARGET_COLUMN" '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == $col) | .id')

if [[ -z "$STATUS_FIELD_ID" || "$STATUS_FIELD_ID" == "null" ]]; then
  echo "Error: Could not find Status field on project" >&2
  exit 1
fi

if [[ -z "$OPTION_ID" || "$OPTION_ID" == "null" ]]; then
  echo "Error: Column '$TARGET_COLUMN' not found. Available columns:" >&2
  echo "$FIELD_DATA" | jq -r '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | .name' >&2
  exit 1
fi

# Move the card
gh api graphql -f query='
  mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { singleSelectOptionId: $optionId }
    }) {
      projectV2Item { id }
    }
  }
' -f projectId="$PROJECT_ID" -f itemId="$ITEM_ID" -f fieldId="$STATUS_FIELD_ID" -f optionId="$OPTION_ID" > /dev/null

# Invalidate cache after write
rm -f "$BOARD_CACHE_FILE" 2>/dev/null

echo "Moved item to $TARGET_COLUMN"
