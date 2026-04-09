#!/bin/bash
# read-board.sh — Read the full GitHub Project board state as structured JSON.
#
# Usage:
#   ./read-board.sh                          # Auto-discover project, read all items
#   ./read-board.sh --project-number 5       # Use specific project number
#   ./read-board.sh --column "In Progress"   # Filter to one column
#   ./read-board.sh --card-id 42             # Get one card by issue number
#   ./read-board.sh --no-cache               # Force fresh read (skip cache)
#
# Output: JSON with columns (Backlog, Design, Ready, In Progress, In Review, Done),
#         cards, and all custom fields (including HasUIChanges, DesignURL).
# Requires: gh CLI with project scopes (gh auth refresh -s read:project -s project)
#
# Caching: Results are cached for 60s. Subsequent calls within the TTL
# return the cached result (filtered as requested). Use --no-cache to bypass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
read-board.sh — Read the full GitHub Project board state as structured JSON.

Usage:
  ./read-board.sh                          # Auto-discover project, read all items
  ./read-board.sh --project-number 5       # Use specific project number
  ./read-board.sh --column "In Progress"   # Filter to one column
  ./read-board.sh --card-id 42             # Get one card by issue number
  ./read-board.sh --no-cache               # Force fresh read (skip cache)

Output: JSON with project info, fields, cards (with all custom field values),
        and a summary grouped by Status column.

Requires: gh CLI with project scopes
  gh auth refresh -h github.com -s read:project -s project
HELP

PROJECT_NUMBER=""
FILTER_COLUMN=""
FILTER_CARD_ID=""
NO_CACHE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-number) PROJECT_NUMBER="$2"; shift 2 ;;
    --column)         FILTER_COLUMN="$2"; shift 2 ;;
    --card-id)        FILTER_CARD_ID="$2"; shift 2 ;;
    --no-cache)       NO_CACHE=true; shift ;;
    *)                echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Check cache (only for unfiltered full-board reads or when we can filter from cache)
if [[ "$NO_CACHE" == "false" && -f "$BOARD_CACHE_FILE" ]]; then
  CACHE_TIME=$(stat -f %m "$BOARD_CACHE_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  CACHE_AGE=$(( NOW - CACHE_TIME ))

  if [[ $CACHE_AGE -lt $BOARD_CACHE_TTL ]]; then
    RESULT=$(cat "$BOARD_CACHE_FILE")

    # Apply filters to cached result
    if [[ -n "$FILTER_COLUMN" ]]; then
      RESULT=$(echo "$RESULT" | jq --arg col "$FILTER_COLUMN" '
        .cards = [.cards[] | select(.fields.Status == $col)]
      ')
    fi
    if [[ -n "$FILTER_CARD_ID" ]]; then
      RESULT=$(echo "$RESULT" | jq --argjson id "$FILTER_CARD_ID" '
        .cards = [.cards[] | select(.issue_number == $id)]
      ')
    fi

    echo "$RESULT"
    exit 0
  fi
fi

# Auto-discover project number if not provided
if [[ -z "$PROJECT_NUMBER" ]]; then
  PROJECT_NUMBER=$(gh project list --owner "$OWNER" --format json | jq -r '.projects[0].number // empty')
  if [[ -z "$PROJECT_NUMBER" ]]; then
    echo '{"error": "No GitHub Project found. Run: /helix-delivery-loop init"}' >&2
    exit 1
  fi
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

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "null" ]]; then
  echo '{"error": "Could not find project #'"$PROJECT_NUMBER"' for '"$OWNER"'"}' >&2
  exit 1
fi

# Read all items with their fields via GraphQL (with pagination)
# Fetches up to 100 items per page, follows cursor for more
ALL_ITEMS="[]"
HAS_NEXT="true"
CURSOR=""

while [[ "$HAS_NEXT" == "true" ]]; do
  PAGE_JSON=$(gh api graphql -f query='
    query($projectId: ID!, $cursor: String) {
      node(id: $projectId) {
        ... on ProjectV2 {
          title
          number
          items(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              content {
                ... on Issue {
                  number
                  title
                  url
                  state
                  labels(first: 10) { nodes { name } }
                  comments(last: 20) { nodes { body author { login } createdAt } }
                }
                ... on PullRequest {
                  number
                  title
                  url
                  state
                  reviewDecision
                }
              }
              fieldValues(first: 30) {
                nodes {
                  ... on ProjectV2ItemFieldTextValue {
                    text
                    field { ... on ProjectV2FieldCommon { name } }
                  }
                  ... on ProjectV2ItemFieldNumberValue {
                    number
                    field { ... on ProjectV2FieldCommon { name } }
                  }
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    field { ... on ProjectV2FieldCommon { name } }
                  }
                  ... on ProjectV2ItemFieldDateValue {
                    date
                    field { ... on ProjectV2FieldCommon { name } }
                  }
                  ... on ProjectV2ItemFieldIterationValue {
                    title
                    field { ... on ProjectV2FieldCommon { name } }
                  }
                }
              }
            }
          }
          fields(first: 30) {
            nodes {
              ... on ProjectV2FieldCommon {
                id
                name
              }
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
  ' -f projectId="$PROJECT_ID" -f cursor="$CURSOR")

  # Append items from this page, filtering out Done cards to reduce payload
  PAGE_ITEMS=$(echo "$PAGE_JSON" | jq '[.data.node.items.nodes[] |
    select(
      [.fieldValues.nodes[] |
        select(.field.name == "Status" and .name == "Done")
      ] | length == 0
    )
  ]')
  ALL_ITEMS=$(echo "$ALL_ITEMS $PAGE_ITEMS" | jq -s '.[0] + .[1]')

  HAS_NEXT=$(echo "$PAGE_JSON" | jq -r '.data.node.items.pageInfo.hasNextPage')
  CURSOR=$(echo "$PAGE_JSON" | jq -r '.data.node.items.pageInfo.endCursor // empty')
done

# Use the last page for project metadata (title, number, fields)
BOARD_JSON="$PAGE_JSON"

# Sanitize: truncate comment bodies to prevent control character issues in jq
# GitHub API can return comments with raw newlines/tabs that break downstream jq parsing
ALL_ITEMS=$(echo "$ALL_ITEMS" | jq '
  [.[] | .content.comments.nodes = [(.content.comments.nodes // [])[] |
    .body = (.body // "" | gsub("[\\n\\r\\t]"; " ") | .[:500])
  ]]
' 2>/dev/null || echo "$ALL_ITEMS")

# Transform into a more usable structure using paginated ALL_ITEMS
RESULT=$(jq -n \
  --argjson items "$ALL_ITEMS" \
  --argjson meta "$BOARD_JSON" \
  --arg projectId "$PROJECT_ID" '
  $meta.data.node as $project |
  {
    project: {
      title: $project.title,
      number: $project.number,
      id: $projectId
    },
    fields: [
      $project.fields.nodes[] |
      {
        id: .id,
        name: .name,
        options: (.options // null)
      }
    ],
    cards: [
      $items[] |
      {
        item_id: .id,
        issue_number: (.content.number // null),
        title: (.content.title // "Draft"),
        url: (.content.url // null),
        state: (.content.state // null),
        review_decision: (.content.reviewDecision // null),
        labels: [(.content.labels.nodes // [])[] | .name],
        recent_comments: [(.content.comments.nodes // [])[] | {body: .body, author: .author.login, created: .createdAt}],
        fields: (
          [.fieldValues.nodes[] | select(.field.name != null)] |
          reduce .[] as $fv (
            {};
            . + {
              ($fv.field.name): ($fv.text // $fv.name // $fv.number // $fv.date // $fv.title // null)
            }
          )
        )
      }
    ],
    _cached_at: (now | todate)
  }
')

# Write full (unfiltered) result to cache
echo "$RESULT" > "$BOARD_CACHE_FILE"

# Apply filters for output
if [[ -n "$FILTER_COLUMN" ]]; then
  RESULT=$(echo "$RESULT" | jq --arg col "$FILTER_COLUMN" '
    .cards = [.cards[] | select(.fields.Status == $col)]
  ')
fi

if [[ -n "$FILTER_CARD_ID" ]]; then
  RESULT=$(echo "$RESULT" | jq --argjson id "$FILTER_CARD_ID" '
    .cards = [.cards[] | select(.issue_number == $id)]
  ')
fi

# Add summary
RESULT=$(echo "$RESULT" | jq '
  . + {
    summary: {
      total: (.cards | length),
      by_column: (
        .cards | group_by(.fields.Status) |
        map({key: (.[0].fields.Status // "No Status"), value: length}) |
        from_entries
      )
    }
  }
')

echo "$RESULT"
