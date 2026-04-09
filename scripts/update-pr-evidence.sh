#!/bin/bash
# update-pr-evidence.sh — Update PR description with screenshots and Visual QA results.
#
# Usage:
#   ./update-pr-evidence.sh --pr 42 --card 137 --result PASS --screenshots "/tmp/a.png /tmp/b.png"
#   ./update-pr-evidence.sh --pr 42 --card 137 --result FAIL --screenshots "/tmp/a.png" --findings "Layout: text clipped"
#
# This script is MANDATORY for the Tester agent. It:
#   1. Uploads screenshots to GitHub Release
#   2. Replaces the PR description with updated evidence section
#   3. Preserves the original PR body above the evidence section

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
update-pr-evidence.sh — Update PR description with screenshots and Visual QA results.

Usage:
  ./update-pr-evidence.sh --pr 42 --card 137 --result PASS --screenshots "file1.png file2.png"
  ./update-pr-evidence.sh --pr 42 --card 137 --result FAIL --screenshots "file1.png" --findings "issue desc"

Options:
  --pr <N>            PR number (required)
  --card <N>          Card/issue number (required)
  --result PASS|FAIL  Visual QA result (required)
  --screenshots <paths>  Space-separated screenshot file paths (required)
  --recording <path>  Screen recording file path (optional)
  --findings <text>   Text description of failures (required if FAIL)
  --checklist <text>  Visual QA checklist markdown (optional)
HELP

PR_NUMBER=""
CARD=""
RESULT=""
SCREENSHOTS=""
RECORDING=""
FINDINGS=""
CHECKLIST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)          PR_NUMBER="$2"; shift 2 ;;
    --card)        CARD="$2"; shift 2 ;;
    --result)      RESULT="$2"; shift 2 ;;
    --screenshots) SCREENSHOTS="$2"; shift 2 ;;
    --recording)   RECORDING="$2"; shift 2 ;;
    --findings)    FINDINGS="$2"; shift 2 ;;
    --checklist)   CHECKLIST="$2"; shift 2 ;;
    *)             log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$PR_NUMBER" ]] && { log_error "--pr required"; exit 1; }
[[ -z "$CARD" ]] && { log_error "--card required"; exit 1; }
[[ -z "$RESULT" ]] && { log_error "--result PASS|FAIL required"; exit 1; }
[[ -z "$SCREENSHOTS" ]] && { log_error "--screenshots required"; exit 1; }

# ── Step 1: Upload screenshots to GitHub Release ──────
log_info "Uploading screenshots to GitHub Release 'screenshots'..."

# Ensure release exists
gh release view screenshots --repo "$REPO" &>/dev/null || \
  gh release create screenshots --repo "$REPO" --title "Screenshots" --notes "Visual evidence for PRs" --latest=false 2>/dev/null || true

SCREENSHOT_URLS=""
for file in $SCREENSHOTS; do
  if [[ ! -f "$file" ]]; then
    log_warn "Screenshot file not found: $file — skipping"
    continue
  fi
  BASENAME=$(basename "$file")
  ASSET_NAME="pr-${PR_NUMBER}-${BASENAME}"
  gh release upload screenshots "$file" --repo "$REPO" --clobber 2>/dev/null && \
    log_info "Uploaded: $ASSET_NAME" || \
    log_warn "Failed to upload: $ASSET_NAME"

  # Build URL using blob/?raw=true pattern (works for private repos)
  SCREENSHOT_URLS="${SCREENSHOT_URLS}<img src=\"https://github.com/${REPO}/releases/download/screenshots/${ASSET_NAME}\" width=\"300\">\n"
done

# Upload recording if provided
RECORDING_URL=""
if [[ -n "$RECORDING" && -f "$RECORDING" ]]; then
  REC_BASENAME=$(basename "$RECORDING")
  REC_ASSET="pr-${PR_NUMBER}-${REC_BASENAME}"
  gh release upload screenshots "$RECORDING" --repo "$REPO" --clobber 2>/dev/null && \
    log_info "Uploaded recording: $REC_ASSET"
  RECORDING_URL="https://github.com/${REPO}/releases/download/screenshots/${REC_ASSET}"
fi

# ── Step 2: Get current PR body (everything above evidence section) ──
CURRENT_BODY=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body -q '.body' 2>/dev/null || echo "")

# Strip any existing Visual QA section (everything from "## Visual QA" onwards)
ORIGINAL_BODY=$(echo "$CURRENT_BODY" | sed '/^## Visual QA/,$d' | sed -e :a -e '/^\n*$/{$d;N;ba}')

# ── Step 3: Build new evidence section ────────────────
EVIDENCE_SECTION="## Visual QA — ${RESULT}

### Screenshots
$(echo -e "$SCREENSHOT_URLS")"

if [[ -n "$RECORDING_URL" ]]; then
  EVIDENCE_SECTION="${EVIDENCE_SECTION}

### Screen Recording
[Recording](${RECORDING_URL})"
fi

if [[ -n "$CHECKLIST" ]]; then
  EVIDENCE_SECTION="${EVIDENCE_SECTION}

### Checklist
${CHECKLIST}"
fi

if [[ "$RESULT" == "FAIL" && -n "$FINDINGS" ]]; then
  EVIDENCE_SECTION="${EVIDENCE_SECTION}

### Findings
${FINDINGS}"
fi

# ── Step 4: Replace PR description ────────────────────
NEW_BODY="${ORIGINAL_BODY}

${EVIDENCE_SECTION}"

gh pr edit "$PR_NUMBER" --repo "$REPO" --body "$NEW_BODY" 2>/dev/null
log_info "Updated PR #${PR_NUMBER} description with Visual QA ${RESULT} and $(echo "$SCREENSHOTS" | wc -w | tr -d ' ') screenshots"

echo "{\"updated\": true, \"result\": \"$RESULT\", \"screenshot_count\": $(echo "$SCREENSHOTS" | wc -w | tr -d ' ')}"
