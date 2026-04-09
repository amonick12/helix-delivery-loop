#!/bin/bash
# create-card.sh — Create a GitHub issue and add it to the project board with fields.
#
# Usage:
#   ./create-card.sh \
#     --title "Fix navigation crash on journal tab" \
#     --body "## Problem\n..." \
#     --priority P1 \
#     --severity P1 \
#     --blast-radius Med \
#     --labels "bug,journal"
#
#   ./create-card.sh \
#     --title "Add voice journaling" \
#     --body-file /tmp/card-body.md \
#     --priority P2 \
#     --severity P2 \
#     --blast-radius Low \
#     --labels "feature,journal"
#
# Requires: gh CLI with project scopes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
create-card.sh — Create a GitHub issue and add it to the project board with fields.

Usage:
  ./create-card.sh \
    --title "Fix navigation crash on journal tab" \
    --body "## Problem\n..." \
    --priority P1 --severity P1 --blast-radius Med \
    --labels "bug,journal"

  ./create-card.sh \
    --title "Add voice journaling" \
    --body-file /tmp/card-body.md \
    --priority P2

Options:
  --title          (required) Issue title
  --body           Issue body text
  --body-file      Read issue body from file (overrides --body)
  --priority       P0, P1, P2, or P3
  --severity       P0, P1, P2, or P3
  --blast-radius   Low, Med, or High
  --risk           Free-text risk description
  --evidence-url   URL to evidence (screenshots, reports)
  --labels         Comma-separated labels (e.g. "bug,journal")
  --project-number Override project number

Requires: gh CLI with project scopes
  gh auth refresh -h github.com -s read:project -s project
HELP

PROJECT_NUMBER=""
TITLE=""
BODY=""
BODY_FILE=""
PRIORITY=""
SEVERITY=""
BLAST_RADIUS=""
RISK=""
EVIDENCE_URL=""
LABELS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)            TITLE="$2"; shift 2 ;;
    --body)             BODY="$2"; shift 2 ;;
    --body-file)        BODY_FILE="$2"; shift 2 ;;
    --priority)         PRIORITY="$2"; shift 2 ;;
    --severity)         SEVERITY="$2"; shift 2 ;;
    --blast-radius)     BLAST_RADIUS="$2"; shift 2 ;;
    --risk)             RISK="$2"; shift 2 ;;
    --evidence-url)     EVIDENCE_URL="$2"; shift 2 ;;
    --labels)           LABELS="$2"; shift 2 ;;
    --project-number)   PROJECT_NUMBER="$2"; shift 2 ;;
    *)                  echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TITLE" ]]; then
  echo "Error: --title is required" >&2
  exit 1
fi

# Read body from file if specified
if [[ -n "$BODY_FILE" && -f "$BODY_FILE" ]]; then
  BODY=$(cat "$BODY_FILE")
fi

if [[ -z "$BODY" ]]; then
  BODY="Created by delivery loop agent."
fi

# Gate: if body references an epic, check epic is approved before creating sub-cards
if echo "$BODY" | grep -qiE '(Part of|Epic)[:#]?\s*#?[0-9]+'; then
  PARENT_EPIC=$(echo "$BODY" | grep -oiE '(Part of|Epic)[:#]?\s*#?([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)
  if [[ -n "$PARENT_EPIC" ]]; then
    if ! bash "$SCRIPT_DIR/validate-epic.sh" --epic "$PARENT_EPIC" 2>/dev/null; then
      echo "Error: Epic #$PARENT_EPIC is not approved. Cannot create sub-cards." >&2
      echo "The user must add the 'epic-approved' label to #$PARENT_EPIC first." >&2
      exit 1
    fi
  fi
fi

# Create the GitHub issue
# Build label args — each label gets its own --label flag
LABEL_ARGS=()
if [[ -n "$LABELS" ]]; then
  IFS=',' read -ra LABEL_LIST <<< "$LABELS"
  for lbl in "${LABEL_LIST[@]}"; do
    LABEL_ARGS+=(--label "$lbl")
  done
fi

ISSUE_URL=$(gh issue create \
  --repo "$OWNER/$REPO" \
  --title "$TITLE" \
  --body "$BODY" \
  "${LABEL_ARGS[@]}" 2>&1 | grep -oE 'https://github.com/[^ ]+')

ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')

echo "Created issue #$ISSUE_NUMBER: $ISSUE_URL"

# Auto-discover project number
if [[ -z "$PROJECT_NUMBER" ]]; then
  PROJECT_NUMBER=$(gh project list --owner "$OWNER" --format json | jq -r '.projects[0].number // empty')
  if [[ -z "$PROJECT_NUMBER" ]]; then
    echo "Warning: No project found. Issue created but not added to board." >&2
    exit 0
  fi
fi

# Add to project
gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$ISSUE_URL" > /dev/null 2>&1
echo "Added to project #$PROJECT_NUMBER"

# Invalidate cache after adding a card
rm -f "$BOARD_CACHE_FILE" 2>/dev/null

# Set custom fields (best-effort — fields may not exist yet)
set_field() {
  local field="$1" value="$2" type="${3:-text}"
  if [[ -n "$value" ]]; then
    "$SCRIPT_DIR/set-field.sh" --issue "$ISSUE_NUMBER" --field "$field" --value "$value" --type "$type" --project-number "$PROJECT_NUMBER" 2>/dev/null || \
      echo "Warning: Could not set $field=$value (field may not exist on project)" >&2
  fi
}

# Set Status to Backlog
"$SCRIPT_DIR/move-card.sh" --issue "$ISSUE_NUMBER" --to "Backlog" --project-number "$PROJECT_NUMBER" 2>/dev/null || \
  echo "Warning: Could not set Status=Backlog (column may not exist)" >&2
set_field "Priority" "$PRIORITY" "select"
set_field "Severity" "$SEVERITY" "select"
set_field "BlastRadius" "$BLAST_RADIUS" "select"
set_field "Risk" "$RISK"
set_field "Evidence URL" "$EVIDENCE_URL"

# Output structured result
echo ""
echo "{"
echo "  \"issue_number\": $ISSUE_NUMBER,"
echo "  \"url\": \"$ISSUE_URL\","
echo "  \"project_number\": $PROJECT_NUMBER,"
echo "  \"title\": \"$TITLE\""
echo "}"
