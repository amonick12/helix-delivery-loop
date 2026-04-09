#!/bin/bash
# create-pr.sh — Create a PR with structured template from a card's worktree.
#
# Usage:
#   ./create-pr.sh --card 137 --branch feature/137-slug --worktree /tmp/helix-wt/feature/137-slug
#
# Output: JSON { "pr_number": N, "pr_url": "..." }
#
# Env:
#   DRY_RUN=1   Skip gh calls, print what would be created

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
create-pr.sh — Create a PR with structured template from a card's worktree.

Usage:
  ./create-pr.sh --card 137 --branch feature/137-slug --worktree /tmp/helix-wt/feature/137-slug

Options:
  --card <N>          Issue number (required)
  --branch <name>     Branch name (required)
  --worktree <path>   Worktree path (required)

Output: JSON { "pr_number": N, "pr_url": "..." }

Env:
  DRY_RUN=1   Skip gh calls, print what would be created
HELP

# ── Parse args ─────────────────────────────────────────
CARD=""
BRANCH=""
WORKTREE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)     CARD="$2"; shift 2 ;;
    --branch)   BRANCH="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    *)          log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$CARD" ]]; then
  log_error "--card <number> is required"
  exit 1
fi
if [[ -z "$BRANCH" ]]; then
  log_error "--branch <name> is required"
  exit 1
fi
if [[ -z "$WORKTREE" ]]; then
  log_error "--worktree <path> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Idempotency: check if PR already exists ──────────
if [[ "$DRY_RUN" != "1" ]]; then
  EXISTING_PR=$(gh pr list --repo "$REPO" --head "$BRANCH" --json number,url --jq '.[0] // empty' 2>/dev/null || echo "")
  if [[ -n "$EXISTING_PR" && "$EXISTING_PR" != "null" ]]; then
    EXISTING_NUM=$(echo "$EXISTING_PR" | jq -r '.number')
    EXISTING_URL=$(echo "$EXISTING_PR" | jq -r '.url')
    log_info "PR already exists for branch $BRANCH: PR #$EXISTING_NUM ($EXISTING_URL)"
    jq -n --argjson pr_number "$EXISTING_NUM" --arg pr_url "$EXISTING_URL" '{pr_number: $pr_number, pr_url: $pr_url}'
    exit 0
  fi
fi

# ── Fetch issue info ──────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  ISSUE_BODY="${MOCK_ISSUE_BODY:-## Acceptance Criteria\n- [ ] Criterion 1\n- [ ] Criterion 2}"
  ISSUE_TITLE="${MOCK_ISSUE_TITLE:-Test Feature}"
else
  ISSUE_BODY=$(gh issue view "$CARD" --repo "$REPO" --json body -q '.body' 2>/dev/null || echo "")
  ISSUE_TITLE=$(gh issue view "$CARD" --repo "$REPO" --json title -q '.title' 2>/dev/null || echo "Card #$CARD")
fi

# ── Extract acceptance criteria as checkboxes ─────────
CRITERIA=$(echo -e "$ISSUE_BODY" | grep -E '^\s*-\s*\[[ xX]\]' || true)
if [[ -z "$CRITERIA" ]]; then
  CRITERIA="- [ ] See issue #$CARD for acceptance criteria"
fi

# ── Get git log from worktree ─────────────────────────
COMMIT_LOG=""
if [[ -d "$WORKTREE" ]]; then
  COMMIT_LOG=$(git -C "$WORKTREE" log --oneline "origin/$BASE_BRANCH..HEAD" 2>/dev/null || echo "No commits yet")
fi

# ── Count test files changed ──────────────────────────
TEST_COUNT=0
if [[ -d "$WORKTREE" ]]; then
  TEST_COUNT=$(git -C "$WORKTREE" diff --name-only "origin/$BASE_BRANCH..HEAD" 2>/dev/null | grep -c 'Tests/' || echo "0")
fi

# ── Check for design URL ─────────────────────────────
DESIGN_URL=""
if [[ "$DRY_RUN" != "1" ]]; then
  DESIGN_URL=$(gh issue view "$CARD" --repo "$REPO" --json body -q '.body' 2>/dev/null | grep -oE 'https://[^ ]*mockup[^ ]*' | head -1 || echo "")
fi

# ── Detect HasUIChanges ──────────────────────────────
HAS_UI_CHANGES="Unknown"
if [[ "$DRY_RUN" != "1" ]]; then
  BOARD_JSON=$("$SCRIPT_DIR/read-board.sh" --card-id "$CARD" 2>/dev/null || echo '{"cards":[]}')
  HAS_UI_CHANGES=$(echo "$BOARD_JSON" | jq -r ".cards[] | select(.issue_number == $CARD) | .fields.HasUIChanges // \"Unknown\"" 2>/dev/null || echo "Unknown")
fi

# ── Build design section ─────────────────────────────
DESIGN_SECTION=""
if [[ -n "$DESIGN_URL" && "$DESIGN_URL" != "null" ]]; then
  DESIGN_SECTION="## Design

![Mockup]($DESIGN_URL)"
elif [[ "$HAS_UI_CHANGES" == "No" ]]; then
  DESIGN_SECTION="## Design

No UI changes for this card."
else
  DESIGN_SECTION="## Design

Design reference pending."
fi

# ── Determine PR type prefix ─────────────────────────
PR_TYPE="feat"
if echo "$ISSUE_TITLE" | grep -qiE '^(fix|bug|crash|error)'; then
  PR_TYPE="fix"
elif echo "$ISSUE_TITLE" | grep -qiE '^(add.*test|xcuitest|test coverage)'; then
  PR_TYPE="test"
elif echo "$ISSUE_TITLE" | grep -qiE '^(refactor|clean|migrate|move)'; then
  PR_TYPE="refactor"
fi

# ── Count files changed by category ──────────────────
FILES_CHANGED=""
if [[ -d "$WORKTREE" ]]; then
  CHANGED_FILES=$(git -C "$WORKTREE" diff --name-only "origin/$BASE_BRANCH..HEAD" 2>/dev/null || echo "")
  VIEW_COUNT=$(echo "$CHANGED_FILES" | grep -c 'Views/' || echo 0)
  VM_COUNT=$(echo "$CHANGED_FILES" | grep -c 'ViewModels/' || echo 0)
  TEST_FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c 'Tests/' || echo 0)
  MODEL_COUNT=$(echo "$CHANGED_FILES" | grep -c 'Models/' || echo 0)
  TOTAL_COUNT=$(echo "$CHANGED_FILES" | grep -c '.' || echo 0)

  FILES_CHANGED="| Category | Files |
|----------|-------|
| Views | $VIEW_COUNT |
| ViewModels | $VM_COUNT |
| Models | $MODEL_COUNT |
| Tests | $TEST_FILE_COUNT |
| **Total** | **$TOTAL_COUNT** |"
fi

# ── Determine UI flag ────────────────────────────────
HAS_UI="Unknown"
if [[ "$HAS_UI_CHANGES" == "Yes" ]]; then
  HAS_UI="Yes"
elif [[ "$HAS_UI_CHANGES" == "No" ]]; then
  HAS_UI="No"
fi

# ── Build PR body ─────────────────────────────────────
PR_TITLE="$PR_TYPE(#$CARD): $ISSUE_TITLE"
# Truncate title to 72 chars
PR_TITLE="${PR_TITLE:0:72}"

# ── Build UI sections conditionally ──────────────────
UI_SECTIONS=""
if [[ "$HAS_UI" != "No" ]]; then
  UI_SECTIONS="## Before/After Screenshots

<!-- Side-by-side table. Tester fills this in via update-pr-evidence.sh -->

| Before | After |
|--------|-------|
| _pending_ | _pending_ |

## Screen Recordings

<!-- Clipped to relevant content, animations ON. Tester fills this in. -->

_pending — Tester will post after Visual QA_

## Visual QA

<!-- Tester posts PASS/FAIL verdict here -->

_pending_"
fi

PR_BODY="## Approval Checklist

### Builder Gates
- [ ] Build passes
- [ ] Unit tests pass
- [ ] Package tests pass
- [ ] SwiftLint: 0 new errors
$(if [[ "$HAS_UI" != "No" ]]; then echo "- [ ] UITest compilation passes
- [ ] Snapshot tests pass (if swift-snapshot-testing added)"; fi)

### Code Review (Reviewer)
- [ ] Code review: 0 P0/P1 findings
- [ ] CLAUDE.md compliance verified

$(if [[ "$HAS_UI" != "No" ]]; then echo "### Visual QA (Tester)
- [ ] XCUITests pass on simulator
- [ ] Before/after screenshots in PR description (same view, same scroll position)
- [ ] Screen recording posted (XCUITests, animations ON)
- [ ] Visual QA pass — design system compliance verified"; fi)

### Merge
- [ ] User approved

---

## Summary

$ISSUE_TITLE

Closes #$CARD

## What Changed

$FILES_CHANGED

<details>
<summary>Commit log</summary>

\`\`\`
$COMMIT_LOG
\`\`\`
</details>

## Acceptance Criteria

$CRITERIA

$DESIGN_SECTION

$UI_SECTIONS

## Code Review

<!-- Reviewer posts findings here -->

_pending_

## Code Coverage

<!-- Coverage % posted by Builder gates -->

_pending_

"

# ── Create PR ─────────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  log_info "[DRY_RUN] Would create PR:"
  log_info "[DRY_RUN]   Title: $PR_TITLE"
  log_info "[DRY_RUN]   Base: $BASE_BRANCH"
  log_info "[DRY_RUN]   Head: $BRANCH"
  log_info "[DRY_RUN]   Body length: ${#PR_BODY} chars"
  jq -n \
    --argjson pr_number 0 \
    --arg pr_url "https://github.com/$REPO/pull/0" \
    '{pr_number: $pr_number, pr_url: $pr_url}'
  exit 0
fi

PR_OUTPUT=$(gh pr create \
  --repo "$REPO" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH" \
  --title "$PR_TITLE" \
  --body "$PR_BODY" 2>&1) || {
  log_error "Failed to create PR: $PR_OUTPUT"
  exit 1
}

# Extract PR URL and number
PR_URL=$(echo "$PR_OUTPUT" | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | head -1)
PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')

if [[ -z "$PR_NUM" ]]; then
  log_error "Could not extract PR number from output: $PR_OUTPUT"
  exit 1
fi

log_info "Created PR #$PR_NUM: $PR_URL"

# ── Initialize checklist ──────────────────────────────
"$SCRIPT_DIR/update-pr-checklist.sh" --pr "$PR_NUM" --card "$CARD" 2>/dev/null || \
  log_warn "Could not initialize PR checklist"

# ── Set PR URL field on card ──────────────────────────
"$SCRIPT_DIR/set-field.sh" --issue "$CARD" --field "PR URL" --value "$PR_URL" 2>/dev/null || \
  log_warn "Could not set PR URL on card #$CARD"

# ── Output JSON ───────────────────────────────────────
jq -n \
  --argjson pr_number "$PR_NUM" \
  --arg pr_url "$PR_URL" \
  '{pr_number: $pr_number, pr_url: $pr_url}'
