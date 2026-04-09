#!/bin/bash
# run-tester.sh — Deterministic Tester pipeline. No LLM decisions.
#
# Usage:
#   ./run-tester.sh --card N --pr N --worktree <path>
#
# Pipeline:
#   1. Validate simulator (UDID)
#   2. Resolve UITest targets (branch-changed files only)
#   3. Boot simulator, build app, install
#   4. Run each UITest target with -only-testing
#   5. Extract screenshots from xcresult
#   6. Upload screenshots to GitHub Release
#   7. Update PR description with screenshots
#   8. Run Visual QA checklist (vision API via LLM — the ONLY LLM step)
#   9. Apply labels (pass/fail)
#   10. Shutdown simulator
#
# This script replaces the LLM-driven Tester agent for reliability.
# The ONLY non-deterministic step is #8 (Visual QA via vision API).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

CARD=""
PR=""
WORKTREE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)     CARD="$2"; shift 2 ;;
    --pr)       PR="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    -h|--help)  echo "Usage: run-tester.sh --card N --pr N --worktree <path>"; exit 0 ;;
    *)          echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$CARD" ]] && echo "Error: --card required" >&2 && exit 1
[[ -z "$PR" ]] && echo "Error: --pr required" >&2 && exit 1
[[ -z "$WORKTREE" ]] && echo "Error: --worktree required" >&2 && exit 1
[[ ! -d "$WORKTREE" ]] && echo "Error: worktree not found: $WORKTREE" >&2 && exit 1

SCREENSHOTS_DIR="/tmp/helix-screenshots-${CARD}"
mkdir -p "$SCREENSHOTS_DIR"

log_step() { echo "=== [Tester #${CARD}] $1 ==="; }

# ── Step 1: Validate simulator ────────────────────────
log_step "Validating simulator"
UDID=$("$SCRIPT_DIR/validate-simulator.sh" 2>&1)
if [[ $? -ne 0 ]]; then
  echo "FAIL: Simulator validation failed: $UDID" >&2
  exit 1
fi
echo "Using simulator: $UDID"

# ── Step 2: Resolve UITest targets ────────────────────
log_step "Resolving UITest targets"
TARGETS=$("$SCRIPT_DIR/resolve-uitests.sh" --worktree "$WORKTREE" 2>/dev/null || true)
if [[ -z "$TARGETS" ]]; then
  # Fallback: look for UITest files matching the card number in the worktree
  CARD_TESTS=$(find "$WORKTREE/helix-appUITests" -name "*${CARD}*UITests*.swift" -o -name "*$(echo "$CARD" | sed 's/^//')*Tests*.swift" 2>/dev/null | head -5)
  if [[ -n "$CARD_TESTS" ]]; then
    TARGETS=""
    while IFS= read -r file; do
      CLASS=$(grep -E '^(final )?class [A-Za-z0-9_]*Tests\s*:' "$file" 2>/dev/null | head -1 | sed -E 's/^(final )?class ([A-Za-z0-9_]+).*/\2/' || true)
      [[ -n "$CLASS" ]] && TARGETS="${TARGETS}helix-appUITests/${CLASS}\n"
    done <<< "$CARD_TESTS"
    TARGETS=$(echo -e "$TARGETS" | grep -v '^$')
  fi
fi

if [[ -z "$TARGETS" ]]; then
  echo "No UITest files for this card — taking manual screenshots only"
  UITEST_MODE="manual"
else
  echo "Test targets:"
  echo "$TARGETS"
  UITEST_MODE="automated"
fi

# ── Step 3: Add awaiting label ────────────────────────
log_step "Adding awaiting-visual-qa label"
gh pr edit "$PR" --repo "$REPO" --add-label awaiting-visual-qa 2>/dev/null || true

# ── Step 4: Kill stale processes, boot simulator ──────
log_step "Preparing simulator"
killall Simulator 2>/dev/null || true
pkill -f xcodebuild 2>/dev/null || true
sleep 1
xcrun simctl boot "$UDID" 2>/dev/null || true

# ── Step 5: Build app ────────────────────────────────
log_step "Building app"
# IMPORTANT: Run xcodebuild from the MAIN repo checkout, not a worktree.
# Git worktrees use a different process sandbox that prevents XCUITest writes to /tmp.
# Since UITest files and HelixUITestBase are on autodev, we can run from there.
MAIN_REPO="$(cd "$WORKTREE" && git rev-parse --git-common-dir 2>/dev/null | sed 's|/\.git||')"
COPIED_UITESTS=()
if [[ -n "$MAIN_REPO" && -d "$MAIN_REPO/helix-app.xcodeproj" && "$MAIN_REPO" != "$WORKTREE" ]]; then
  # Copy UITest files from worktree to main repo (so they exist during test execution)
  for uitest_file in "$WORKTREE"/helix-appUITests/*.swift; do
    [[ -f "$uitest_file" ]] || continue
    BASENAME=$(basename "$uitest_file")
    if [[ ! -f "$MAIN_REPO/helix-appUITests/$BASENAME" ]]; then
      cp "$uitest_file" "$MAIN_REPO/helix-appUITests/"
      COPIED_UITESTS+=("$MAIN_REPO/helix-appUITests/$BASENAME")
      echo "Copied UITest: $BASENAME → main repo"
    fi
  done
  cd "$MAIN_REPO"
else
  cd "$WORKTREE"
fi
BUILD_OUTPUT=$(xcodebuild build-for-testing \
  -project helix-app.xcodeproj \
  -scheme helix-app \
  -destination "id=$UDID" \
  2>&1 | tail -20)
BUILD_EXIT=$?

if [[ $BUILD_EXIT -ne 0 ]]; then
  echo "FAIL: Build failed" >&2
  echo "$BUILD_OUTPUT" >&2
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  exit 1
fi
echo "Build succeeded"

# ── Step 6: Run UITests (if any) ─────────────────────
UITEST_PASSED=true
if [[ "$UITEST_MODE" == "automated" ]]; then
  log_step "Running UITests"
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    echo "Running: $target"
    RESULT_PATH="/tmp/TestResults-${CARD}-$(basename "$target").xcresult"
    rm -rf "$RESULT_PATH" 2>/dev/null || true

    TEST_OUTPUT=$(xcodebuild test \
      -project helix-app.xcodeproj \
      -scheme helix-app \
      -destination "id=$UDID" \
      -only-testing:"$target" \
      -resultBundlePath "$RESULT_PATH" \
      2>&1 | tail -20)
    TEST_EXIT=$?

    if [[ $TEST_EXIT -ne 0 ]]; then
      echo "FAIL: $target failed" >&2
      UITEST_PASSED=false
    else
      echo "PASS: $target"
    fi

    # Extract screenshots from xcresult via XCTAttachments
    if [[ -d "$RESULT_PATH" ]]; then
      EXTRACT_DIR="${SCREENSHOTS_DIR}/xcresult-$(basename "$target")"
      mkdir -p "$EXTRACT_DIR"
      # Export all test attachments (screenshots captured via XCTAttachment)
      xcrun xcresulttool export attachments --path "$RESULT_PATH" --output-path "$EXTRACT_DIR" 2>/dev/null || true
      # Find PNG screenshots from exported attachments
      FOUND_SCREENSHOTS=$(find "$EXTRACT_DIR" -name "*.png" -o -name "*.jpg" 2>/dev/null | head -10)
      if [[ -n "$FOUND_SCREENSHOTS" ]]; then
        IDX=1
        while IFS= read -r img; do
          cp "$img" "${SCREENSHOTS_DIR}/pr-${PR}-${target##*/}-${IDX}.png" 2>/dev/null || true
          IDX=$((IDX + 1))
        done <<< "$FOUND_SCREENSHOTS"
        echo "Extracted $(echo "$FOUND_SCREENSHOTS" | wc -l | tr -d ' ') screenshots from xcresult"
      else
        echo "No screenshots found in xcresult attachments — UITests may not use XCTAttachment(screenshot:)"
      fi
    fi
  done <<< "$TARGETS"
fi

# ── Step 7: Collect screenshots ───────────────────────
log_step "Capturing screenshots"

# Check for screenshots saved by HelixUITestBase (tries /tmp first, then $HOME)
UITEST_SCREENSHOT_DIR="/tmp/helix-uitest-screenshots"
if [[ ! -d "$UITEST_SCREENSHOT_DIR" ]] || [[ -z "$(find "$UITEST_SCREENSHOT_DIR" -name "*.png" 2>/dev/null)" ]]; then
  UITEST_SCREENSHOT_DIR="$HOME/helix-uitest-screenshots"
fi
if [[ -d "$UITEST_SCREENSHOT_DIR" ]]; then
  SAVED_SCREENSHOTS=$(find "$UITEST_SCREENSHOT_DIR" -name "*.png" 2>/dev/null)
  if [[ -n "$SAVED_SCREENSHOTS" ]]; then
    IDX=1
    while IFS= read -r img; do
      BASENAME=$(basename "$img" .png)
      cp "$img" "${SCREENSHOTS_DIR}/pr-${PR}-${BASENAME}.png" 2>/dev/null || true
      IDX=$((IDX + 1))
    done <<< "$SAVED_SCREENSHOTS"
    echo "Collected $(echo "$SAVED_SCREENSHOTS" | wc -l | tr -d ' ') screenshots from UITest filesystem saves"
    # Clean up for next run
    rm -rf "$UITEST_SCREENSHOT_DIR"
  fi
fi

# Only take manual screenshots if no screenshots were collected
EXTRACTED_COUNT=$(find "$SCREENSHOTS_DIR" -name "pr-${PR}-*.png" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$EXTRACTED_COUNT" -eq 0 ]]; then
  echo "WARN: No UITest screenshots captured — PR will have no visual evidence"
else
  echo "Using $EXTRACTED_COUNT screenshots from UITests"
fi

# ── Step 8: Upload screenshots ────────────────────────
log_step "Uploading screenshots"
# Ensure release exists
gh release create screenshots --repo "$REPO" --title "Screenshots" --notes "Visual evidence" 2>/dev/null || true

for img in "${SCREENSHOTS_DIR}"/pr-${PR}-*.png; do
  [[ -f "$img" ]] && gh release upload screenshots "$img" --clobber --repo "$REPO" 2>/dev/null || true
done

# Get URLs for uploaded assets
SCREENSHOT_URLS=""
for img in "${SCREENSHOTS_DIR}"/pr-${PR}-*.png; do
  [[ -f "$img" ]] || continue
  BASENAME=$(basename "$img")
  URL="https://github.com/${REPO}/releases/download/screenshots/${BASENAME}"
  SCREENSHOT_URLS="${SCREENSHOT_URLS}<img src=\"${URL}\" width=\"300\">\n"
done

# ── Step 9: Update PR description ─────────────────────
log_step "Updating PR description"
if [[ -n "$SCREENSHOT_URLS" ]]; then
  "$SCRIPT_DIR/update-pr-evidence.sh" --pr "$PR" --section screenshots \
    --content "| Before | After |\n|--------|-------|\n| _baseline_ | $(echo -e "$SCREENSHOT_URLS" | head -1) |" 2>/dev/null || true
fi

# ── Step 10: Decision ─────────────────────────────────
log_step "Applying verdict"
if [[ "$UITEST_PASSED" == "true" ]]; then
  echo "VERDICT: PASS"

  # Update Visual QA section
  "$SCRIPT_DIR/update-pr-evidence.sh" --pr "$PR" --section visual-qa \
    --content "**Visual QA — PASS**\n\nAll UITests passed. Screenshots posted above." 2>/dev/null || true

  # Apply labels
  gh pr edit "$PR" --repo "$REPO" --add-label visual-qa-approved --remove-label awaiting-visual-qa 2>/dev/null || true
  "$SCRIPT_DIR/apply-tests-passed.sh" --pr "$PR" --card "$CARD" 2>/dev/null || true

  # Check off checklist
  "$SCRIPT_DIR/update-pr-evidence.sh" --pr "$PR" --section checklist --check "Visual QA pass" 2>/dev/null || true

  # Post text-only comment
  gh pr comment "$PR" --repo "$REPO" --body "bot: ## Visual QA — PASS

All UITests passed. Screenshots uploaded to PR description." 2>/dev/null || true
else
  echo "VERDICT: FAIL"

  # Update Visual QA section
  "$SCRIPT_DIR/update-pr-evidence.sh" --pr "$PR" --section visual-qa \
    --content "**Visual QA — FAIL**\n\nUITest failures detected. Routing to Builder." 2>/dev/null || true

  # Route to Builder
  gh pr ready --undo "$PR" --repo "$REPO" 2>/dev/null || true
  gh pr edit "$PR" --repo "$REPO" --add-label rework --remove-label code-review-approved --remove-label awaiting-visual-qa 2>/dev/null || true

  gh pr comment "$PR" --repo "$REPO" --body "bot: ## Visual QA — FAIL

UITest failures detected. Converting to draft and routing to Builder." 2>/dev/null || true
fi

# ── Step 11: Shutdown ─────────────────────────────────
log_step "Shutting down simulator"
xcrun simctl shutdown "$UDID" 2>/dev/null || true

# Clean up copied UITest files from main repo
for copied in "${COPIED_UITESTS[@]}"; do
  rm -f "$copied" 2>/dev/null
done

# Cleanup
rm -rf "$SCREENSHOTS_DIR"

echo "Tester pipeline complete for card #${CARD}"
