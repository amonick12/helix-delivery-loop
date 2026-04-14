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

# ── Step 1: Upload screenshots to PUBLIC release on the plugin repo ──
# CRITICAL: The helix repo is PRIVATE. GitHub renders PR body images via
# anonymous fetches (raw.githubusercontent.com / releases/download), so any
# URL that points at the private repo returns 404 to the renderer regardless
# of whether the viewer is signed in. The ONLY URL form that reliably works
# in a private-repo PR body is one that points at a PUBLIC repo.
#
# We host screenshots in the public helix-delivery-loop plugin repo's
# "screenshots" release. Asset names are prefixed with the card id so PRs
# never collide.
SCREENSHOT_HOST_REPO="amonick12/helix-delivery-loop"
RELEASE_TAG="screenshots"
log_info "Uploading screenshots to PUBLIC release ${SCREENSHOT_HOST_REPO}/${RELEASE_TAG}..."

SCREENSHOT_URLS=""
UPLOADED_URLS=()
for file in $SCREENSHOTS; do
  FILE_PATH="$file"
  if [[ "$FILE_PATH" != /* ]]; then
    FILE_PATH="$(pwd)/$FILE_PATH"
  fi

  if [[ ! -f "$FILE_PATH" ]]; then
    log_warn "Screenshot not found: $file — skipping"
    continue
  fi

  BASENAME="$(basename "$FILE_PATH")"
  # Card-prefixed name — stable across runs of the same card so the PR body
  # always points at the latest evidence.
  ASSET_NAME="${CARD}-${BASENAME}"
  TMPFILE="/tmp/${ASSET_NAME}"
  cp "$FILE_PATH" "$TMPFILE"

  if ! gh release upload "$RELEASE_TAG" "$TMPFILE" --repo "$SCREENSHOT_HOST_REPO" --clobber 2>&1 | tee -a /tmp/screenshot-upload.log >/dev/null; then
    log_error "Public release upload failed for $file — refusing to emit a broken URL"
    rm -f "$TMPFILE"
    exit 1
  fi
  rm -f "$TMPFILE"

  UPLOAD_URL="https://github.com/${SCREENSHOT_HOST_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"

  # MANDATORY render-check: fetch ANONYMOUSLY (no auth header). If this
  # returns anything other than HTTP 200 with non-zero content-length, the
  # PR renderer will show a broken image — fail fast instead of writing
  # a useless URL into the PR body.
  HTTP_HEAD=$(curl -sIL "$UPLOAD_URL" 2>&1)
  STATUS=$(echo "$HTTP_HEAD" | grep -E '^HTTP/' | tail -1 | awk '{print $2}')
  CLEN=$(echo "$HTTP_HEAD" | grep -i '^content-length:' | tail -1 | awk '{print $2}' | tr -d '\r')
  if [[ "$STATUS" != "200" || "${CLEN:-0}" -lt 1000 ]]; then
    log_error "Render-check FAILED for $UPLOAD_URL (status=$STATUS, content-length=$CLEN). Refusing to write a broken image URL into the PR body."
    exit 1
  fi

  SCREENSHOT_URLS="${SCREENSHOT_URLS}<img src=\"${UPLOAD_URL}\" width=\"300\">\n"
  UPLOADED_URLS+=("$UPLOAD_URL")
  log_info "Uploaded + verified: ${BASENAME} → $UPLOAD_URL"
done

if [[ ${#UPLOADED_URLS[@]} -eq 0 ]]; then
  log_error "No screenshots uploaded successfully. Refusing to update PR body."
  exit 1
fi

# Upload recording too if provided — same public host
RECORDING_URL=""
if [[ -n "$RECORDING" && -f "$RECORDING" ]]; then
  REC_BASENAME="$(basename "$RECORDING")"
  REC_ASSET="${CARD}-${REC_BASENAME}"
  TMPFILE="/tmp/${REC_ASSET}"
  cp "$RECORDING" "$TMPFILE"
  if gh release upload "$RELEASE_TAG" "$TMPFILE" --repo "$SCREENSHOT_HOST_REPO" --clobber 2>/dev/null; then
    RECORDING_URL="https://github.com/${SCREENSHOT_HOST_REPO}/releases/download/${RELEASE_TAG}/${REC_ASSET}"
    log_info "Uploaded recording: $RECORDING_URL"
  else
    log_warn "Recording upload failed"
  fi
  rm -f "$TMPFILE"
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
