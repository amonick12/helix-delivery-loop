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

# ── Step 1: Upload screenshots to catbox.moe ─────────────
# catbox.moe is an anonymous image host with no rate limits. The returned URLs
# are public and render in private repo PR markdown without any auth dance.
#
# We accept both absolute paths (e.g. /tmp/helix-wt/feature/X/Packages/.../foo.png)
# and repo-relative paths. The actual file content is uploaded — the path is
# only used to find the file.
log_info "Uploading screenshots to catbox.moe..."

SCREENSHOT_URLS=""
for file in $SCREENSHOTS; do
  # Resolve to absolute path
  FILE_PATH="$file"
  if [[ "$FILE_PATH" != /* ]]; then
    FILE_PATH="$(pwd)/$FILE_PATH"
  fi

  if [[ ! -f "$FILE_PATH" ]]; then
    log_warn "Screenshot not found: $file — skipping"
    continue
  fi

  # Upload to catbox.moe
  UPLOAD_URL=$(curl -sF "reqtype=fileupload" -F "fileToUpload=@${FILE_PATH}" https://catbox.moe/user/api.php 2>/dev/null || echo "")

  if [[ -z "$UPLOAD_URL" || "$UPLOAD_URL" != https://* ]]; then
    log_warn "catbox upload failed for $file (got: '$UPLOAD_URL')"
    continue
  fi

  # Verify the URL resolves
  HTTP_CODE=$(curl -sI "$UPLOAD_URL" 2>/dev/null | head -1 | awk '{print $2}')
  if [[ "$HTTP_CODE" != "200" ]]; then
    log_warn "catbox URL returned HTTP $HTTP_CODE for $file: $UPLOAD_URL"
    continue
  fi

  SCREENSHOT_URLS="${SCREENSHOT_URLS}<img src=\"${UPLOAD_URL}\" width=\"300\">\n"
  log_info "Uploaded: $(basename "$FILE_PATH") → $UPLOAD_URL"
done

# Upload recording too if provided
RECORDING_URL=""
if [[ -n "$RECORDING" && -f "$RECORDING" ]]; then
  RECORDING_URL=$(curl -sF "reqtype=fileupload" -F "fileToUpload=@${RECORDING}" https://catbox.moe/user/api.php 2>/dev/null || echo "")
  if [[ "$RECORDING_URL" == https://* ]]; then
    log_info "Uploaded recording: $RECORDING_URL"
  else
    log_warn "Recording upload failed"
    RECORDING_URL=""
  fi
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
