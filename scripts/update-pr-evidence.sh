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

# ── Step 1: Reference snapshot test images committed to the feature branch ──
# The Builder is required to add SwiftUI snapshot tests for UI cards (see builder
# agent docs). Those tests commit reference images to `__Snapshots__/*.png` on
# the feature branch. We reference those directly via blob/?raw=true URLs — no
# separate branch, no asset uploads, and they double as regression gates.
#
# The --screenshots arg should contain paths RELATIVE to the repo root on the
# feature branch, e.g. "Packages/FeatureSettings/Tests/.../__Snapshots__/foo.png"
log_info "Building screenshot URLs from feature branch paths..."

# Discover the feature branch from the PR
FEATURE_BRANCH=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefName -q '.headRefName' 2>/dev/null || echo "")
if [[ -z "$FEATURE_BRANCH" ]]; then
  log_error "Could not determine feature branch for PR #${PR_NUMBER}"
  exit 1
fi
log_info "Feature branch: $FEATURE_BRANCH"

SCREENSHOT_URLS=""
for file in $SCREENSHOTS; do
  # Strip any absolute prefix so we have a repo-relative path
  REL_PATH="$file"
  REL_PATH="${REL_PATH#/tmp/helix-wt/feature/*/}"
  REL_PATH="${REL_PATH#$(pwd)/}"

  # blob/?raw=true URL — proven to work in private repo PR markdown
  ASSET_URL="https://github.com/${REPO}/blob/${FEATURE_BRANCH}/${REL_PATH}?raw=true"
  SCREENSHOT_URLS="${SCREENSHOT_URLS}<img src=\"${ASSET_URL}\" width=\"300\">\n"
  log_info "Referencing: ${REL_PATH}"
done

# Handle recording (simulator recordings still need a host — use user-attachments
# or a committed temp location; for now keep recording out of the evidence flow)
RECORDING_URL=""
if [[ -n "$RECORDING" && -f "$RECORDING" ]]; then
  log_warn "Recording support disabled in evidence flow — snapshot tests only"
fi

# ── Step 2: Get current PR body (everything above evidence section) ──
CURRENT_BODY=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body -q '.body' 2>/dev/null || echo "")

# Strip any existing Visual QA section (everything from "## Visual QA" onwards)
ORIGINAL_BODY=$(echo "$CURRENT_BODY" | awk '/^## Visual QA/{exit} {print}')

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
