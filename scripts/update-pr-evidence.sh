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

# ── Step 0: Verify each screenshot looks like a real device capture ─
# Reject snapshot-test PNGs and standalone-view renders before uploading.
# verify-screenshot-chrome.sh checks dimensions and bottom-strip color
# variance; both must pass.
SCRIPT_DIR_VPE="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "$SCRIPT_DIR_VPE/verify-screenshot-chrome.sh" ]]; then
  if ! bash "$SCRIPT_DIR_VPE/verify-screenshot-chrome.sh" $SCREENSHOTS; then
    log_error "Screenshot verification failed. Refusing to upload images that are not real device captures."
    log_error "Re-capture with: xcrun simctl io booted screenshot <out.png> after launching the app."
    exit 1
  fi
fi

# ── Step 1: Upload screenshots to GitHub Release assets ───
# GitHub Release assets are served authenticated for private repos, so they
# render correctly in PR markdown for anyone with repo access. We upload to
# the "screenshots" release tag with unique names to avoid collisions.
RELEASE_TAG="screenshots"
log_info "Uploading screenshots to GitHub Release '$RELEASE_TAG'..."

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

  # Unique asset name: card-pr-timestamp-basename
  BASENAME="$(basename "$FILE_PATH")"
  ASSET_NAME="card${CARD}-pr${PR_NUMBER}-$(date +%s)-${BASENAME}"

  # Upload to GitHub Release (--clobber replaces if name collision)
  if ! gh release upload "$RELEASE_TAG" "$FILE_PATH" --repo "$REPO" --clobber 2>/dev/null; then
    # Retry with unique name by copying
    TMPFILE="/tmp/${ASSET_NAME}"
    cp "$FILE_PATH" "$TMPFILE"
    if ! gh release upload "$RELEASE_TAG" "$TMPFILE#${ASSET_NAME}" --repo "$REPO" --clobber 2>/dev/null; then
      log_warn "GitHub release upload failed for $file"
      rm -f "$TMPFILE"
      continue
    fi
    rm -f "$TMPFILE"
    UPLOAD_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
  else
    UPLOAD_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${BASENAME}"
  fi

  SCREENSHOT_URLS="${SCREENSHOT_URLS}<img src=\"${UPLOAD_URL}\" width=\"300\">\n"
  log_info "Uploaded: ${BASENAME} → $UPLOAD_URL"
done

# Upload recording too if provided
RECORDING_URL=""
if [[ -n "$RECORDING" && -f "$RECORDING" ]]; then
  REC_BASENAME="$(basename "$RECORDING")"
  REC_ASSET="card${CARD}-pr${PR_NUMBER}-$(date +%s)-${REC_BASENAME}"
  TMPFILE="/tmp/${REC_ASSET}"
  cp "$RECORDING" "$TMPFILE"
  if gh release upload "$RELEASE_TAG" "$TMPFILE#${REC_ASSET}" --repo "$REPO" --clobber 2>/dev/null; then
    RECORDING_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${REC_ASSET}"
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

BODY_FILE="/tmp/pr-${PR_NUMBER}-evidence-$(date +%s).md"
printf '%s' "$NEW_BODY" > "$BODY_FILE"

# Gate: every image/media URL referenced in the new body must resolve.
if ! bash "$SCRIPT_DIR/verify-image-urls.sh" "$BODY_FILE" >/dev/null; then
  log_error "Image URL verification failed — refusing to post broken images."
  bash "$SCRIPT_DIR/verify-image-urls.sh" "$BODY_FILE" >&2 || true
  rm -f "$BODY_FILE"
  echo "{\"updated\": false, \"error\": \"broken image urls\"}"
  exit 2
fi

gh pr edit "$PR_NUMBER" --repo "$REPO" --body-file "$BODY_FILE" 2>/dev/null
rm -f "$BODY_FILE"
log_info "Updated PR #${PR_NUMBER} description with Visual QA ${RESULT} and $(echo "$SCREENSHOTS" | wc -w | tr -d ' ') screenshots"

echo "{\"updated\": true, \"result\": \"$RESULT\", \"screenshot_count\": $(echo "$SCREENSHOTS" | wc -w | tr -d ' ')}"
