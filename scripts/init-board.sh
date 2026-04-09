#!/bin/bash
# init-board.sh — Bootstrap a GitHub Project board by copying the template project.
#
# Usage:
#   ./init-board.sh                          # Copy template, add custom fields, create labels
#   ./init-board.sh --project-number 3       # Add fields to existing project (skip copy)
#   ./init-board.sh --dry-run                # Show what would be created
#
# Strategy: Copies project #1 (amonick12's kanban board) which already has:
#   - Board layout with 6 Status columns (Backlog, Design, Ready, In Progress, In Review, Done)
#   - Priority select field (P0, P1, P2)
# Then adds delivery-loop custom fields on top.
#
# Requires: gh CLI with project scopes (gh auth refresh -h github.com -s read:project -s project)

set -euo pipefail

OWNER="amonick12"
REPO="helix"
TEMPLATE_PROJECT_NUMBER=1
PROJECT_NUMBER=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-number)   PROJECT_NUMBER="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=true; shift ;;
    *)                  echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

echo "=== Helix Delivery Loop — Board Setup ==="
echo ""

# Step 1: Create or discover project
if [[ -z "$PROJECT_NUMBER" ]]; then
  # Check if "Helix Delivery" project already exists
  EXISTING=$(gh project list --owner "$OWNER" --format json 2>/dev/null | jq -r '.projects[] | select(.title == "Helix Delivery") | .number' || echo "")

  if [[ -n "$EXISTING" ]]; then
    PROJECT_NUMBER="$EXISTING"
    echo "Found existing project: #$PROJECT_NUMBER"
  else
    if $DRY_RUN; then
      echo "[DRY RUN] Would copy project #$TEMPLATE_PROJECT_NUMBER as 'Helix Delivery'"
      echo "[DRY RUN] Would add custom fields:"
      echo "  Text: Branch, PR URL, Evidence URL, Validation Report URL, Risk, ReworkReason, BlockedReason, Severity, BlastRadius, ApprovalStatus, MergeStatus, DesignURL"
      echo "  SingleSelect: HasUIChanges (Yes,No)"
      echo "  Number: LoopCount"
      echo "[DRY RUN] Would ensure Status columns: Backlog, Design, Ready, In Progress, In Review, Done"
      echo "[DRY RUN] Would create repo labels"
      echo ""
      echo "=== Dry run complete ==="
      exit 0
    fi

    echo "Copying template project #$TEMPLATE_PROJECT_NUMBER → 'Helix Delivery'..."

    # Get source project ID and owner ID
    SOURCE_ID=$(gh api graphql -f query='
      query($owner: String!, $number: Int!) {
        user(login: $owner) {
          projectV2(number: $number) { id }
        }
      }
    ' -f owner="$OWNER" -F number="$TEMPLATE_PROJECT_NUMBER" --jq '.data.user.projectV2.id')

    OWNER_ID=$(gh api graphql -f query='
      query($login: String!) {
        user(login: $login) { id }
      }
    ' -f login="$OWNER" --jq '.data.user.id')

    # Copy the project (gets Board layout + Status columns + Priority field)
    COPY_RESULT=$(gh api graphql -f query='
      mutation($ownerId: ID!, $projectId: ID!, $title: String!) {
        copyProjectV2(input: {
          ownerId: $ownerId
          projectId: $projectId
          title: $title
          includeDraftIssues: false
        }) {
          projectV2 {
            id
            number
            url
            views(first: 5) {
              nodes { name layout }
            }
          }
        }
      }
    ' -f ownerId="$OWNER_ID" -f projectId="$SOURCE_ID" -f title="Helix Delivery")

    PROJECT_NUMBER=$(echo "$COPY_RESULT" | jq -r '.data.copyProjectV2.projectV2.number')
    PROJECT_URL=$(echo "$COPY_RESULT" | jq -r '.data.copyProjectV2.projectV2.url')

    echo "Created project #$PROJECT_NUMBER: $PROJECT_URL"

    # Show the views we inherited
    echo ""
    echo "Board views:"
    echo "$COPY_RESULT" | jq -r '.data.copyProjectV2.projectV2.views.nodes[] | "  ✓ \(.name) (\(.layout))"'
  fi
fi

# Get project global ID
PROJECT_ID=$(gh api graphql -f query='
  query($owner: String!, $number: Int!) {
    user(login: $owner) {
      projectV2(number: $number) { id }
    }
  }
' -f owner="$OWNER" -F number="$PROJECT_NUMBER" --jq '.data.user.projectV2.id')

# Step 2: Check and add custom fields
echo ""
echo "--- Adding custom fields ---"

EXISTING_FIELDS=$(gh api graphql -f query='
  query($projectId: ID!) {
    node(id: $projectId) {
      ... on ProjectV2 {
        fields(first: 30) {
          nodes {
            ... on ProjectV2FieldCommon { name }
          }
        }
      }
    }
  }
' -f projectId="$PROJECT_ID" | jq -r '.data.node.fields.nodes[] | select(.name != null) | .name')

field_exists() {
  echo "$EXISTING_FIELDS" | grep -qx "$1"
}

create_text_field() {
  local name="$1"
  if field_exists "$name"; then
    echo "  ✓ $name (exists)"
  else
    gh api graphql -f query="
      mutation {
        createProjectV2Field(input: {
          projectId: \"$PROJECT_ID\"
          dataType: TEXT
          name: \"$name\"
        }) {
          projectV2Field { ... on ProjectV2FieldCommon { name } }
        }
      }
    " > /dev/null 2>&1 && echo "  + $name" || echo "  ! $name (failed)"
  fi
}

# Alias used by v2 field list
add_text_field() { create_text_field "$@"; }

create_number_field() {
  local name="$1"
  if field_exists "$name"; then
    echo "  ✓ $name (exists)"
  else
    gh api graphql -f query="
      mutation {
        createProjectV2Field(input: {
          projectId: \"$PROJECT_ID\"
          dataType: NUMBER
          name: \"$name\"
        }) {
          projectV2Field { ... on ProjectV2FieldCommon { name } }
        }
      }
    " > /dev/null 2>&1 && echo "  + $name" || echo "  ! $name (failed)"
  fi
}

create_single_select_field() {
  local name="$1"
  local options_csv="$2"
  if field_exists "$name"; then
    echo "  ✓ $name (exists)"
  else
    # Build options array from comma-separated string
    local options_json
    options_json=$(echo "$options_csv" | tr ',' '\n' | jq -R '{name: .}' | jq -s '.')
    gh api graphql -f query="
      mutation(\$options: [ProjectV2SingleSelectFieldOptionInput!]!) {
        createProjectV2Field(input: {
          projectId: \"$PROJECT_ID\"
          dataType: SINGLE_SELECT
          name: \"$name\"
          singleSelectOptions: \$options
        }) {
          projectV2Field { ... on ProjectV2FieldCommon { name } }
        }
      }
    " --argjson options "$options_json" > /dev/null 2>&1 && echo "  + $name" || echo "  ! $name (failed)"
  fi
}

# Alias used by v2 field list
add_single_select_field() { create_single_select_field "$@"; }

echo ""
echo "Text fields:"
create_text_field "Branch"
create_text_field "PR URL"
create_text_field "Evidence URL"
create_text_field "Validation Report URL"
create_text_field "Risk"
create_text_field "ReworkReason"
create_text_field "BlockedReason"
echo ""
echo "Select fields:"
create_single_select_field "Severity" "P0,P1,P2,P3"
create_single_select_field "BlastRadius" "Low,Med,High"
create_single_select_field "ApprovalStatus" "Pending,Approved"
create_single_select_field "MergeStatus" "Pending,Merged,Failed"

# New v2 fields
add_text_field "DesignURL"
add_single_select_field "HasUIChanges" "Yes,No"

echo ""
echo "Number fields:"
create_number_field "LoopCount"

# Step 3: Status columns — ensure required v2 columns exist
# Required order: Backlog, Design, Ready, In Progress, In Review, Done
echo ""
echo "--- Status columns ---"

STATUS_FIELD_JSON=$(gh api graphql -f query='
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

STATUS_FIELD_ID=$(echo "$STATUS_FIELD_JSON" | jq -r '.data.node.fields.nodes[] | select(.name == "Status") | .id')
STATUS_OPTIONS=$(echo "$STATUS_FIELD_JSON" | jq -r '.data.node.fields.nodes[] | select(.name == "Status") | .options[] | .name')

for col in $STATUS_OPTIONS; do
  echo "  ✓ $col"
done

# Add "Design" column if it is missing
if ! echo "$STATUS_OPTIONS" | grep -qx "Design"; then
  echo "  + Design (creating...)"
  gh api graphql -f query='
    mutation($fieldId: ID!, $name: String!) {
      addProjectV2SingleSelectFieldOption(input: {
        fieldId: $fieldId
        name: $name
        color: PURPLE
        description: "Design in progress"
      }) {
        option { id name }
      }
    }
  ' -f fieldId="$STATUS_FIELD_ID" -f name="Design" > /dev/null 2>&1 && \
    echo "  + Design (created)" || echo "  ! Design (failed — may need manual reorder in UI)"
  echo "  NOTE: Reorder columns in the board UI to: Backlog, Design, Ready, In Progress, In Review, Done"
else
  echo "  ✓ Design (exists)"
fi

# Step 4: Create recommended labels on the repo
echo ""
echo "--- Repo labels ---"

RECOMMENDED_LABELS=(
  "bug:d73a4a"
  "feature:0075ca"
  "enhancement:a2eeef"
  "journal:5319e7"
  "practices:006b75"
  "insights:e99695"
  "knowledge:f9d0c4"
  "settings:c5def5"
  "onboarding:bfdadc"
  "cognition:1d76db"
  "p0-critical:b60205"
  "p1-high:d93f0b"
  "p2-medium:fbca04"
  "p3-low:0e8a16"
  "user-approved:0e8a16"
)

for label_spec in "${RECOMMENDED_LABELS[@]}"; do
  label_name="${label_spec%%:*}"
  label_color="${label_spec##*:}"
  if gh label list --repo "$OWNER/$REPO" --json name --jq ".[].name" 2>/dev/null | grep -qx "$label_name"; then
    echo "  ✓ $label_name"
  else
    gh label create "$label_name" --repo "$OWNER/$REPO" --color "$label_color" 2>/dev/null && \
      echo "  + $label_name" || \
      echo "  ! $label_name (failed)"
  fi
done

echo ""
echo "=== Setup complete ==="
echo "Project: https://github.com/users/$OWNER/projects/$PROJECT_NUMBER"
echo ""
echo "Next steps:"
echo "  1. Run: /helix-delivery-loop status"
echo "  2. Create cards or run Scout to populate Backlog"
echo "  3. Drag cards from Backlog → Ready to start the pipeline"
