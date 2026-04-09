#!/bin/bash
# verify-ui-requirements.sh — Validate UI card requirements before push.
#
# For cards with HasUIChanges=Yes, checks that XCUITests exist,
# fixture data is present, and tests compile.
#
# Usage:
#   ./verify-ui-requirements.sh --card N --worktree <path>
#
# Output: JSON { card, has_ui, requirements[], missing[] }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
verify-ui-requirements.sh — Validate UI card requirements.

Usage:
  ./verify-ui-requirements.sh --card N --worktree <path>

Checks (for UI cards): XCUITests exist, fixture data, tests compile.
Skips all checks for non-UI cards.
HELP

CARD=""
WORKTREE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)     CARD="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    *)          log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$CARD" ]] && log_error "--card required" && exit 1

# Find worktree if not provided
if [[ -z "$WORKTREE" ]]; then
  for wt in /tmp/helix-wt/feature/${CARD}-*; do
    [[ -d "$wt" ]] && WORKTREE="$wt" && break
  done
fi
[[ -z "$WORKTREE" || ! -d "$WORKTREE" ]] && log_error "No worktree found for card #$CARD" && exit 1

# Check if this is a UI card
BOARD=$(bash "$SCRIPT_DIR/read-board.sh" 2>/dev/null || echo '{"cards":[]}')
HAS_UI=$(echo "$BOARD" | jq -r --argjson c "$CARD" '[.cards[] | select(.issue_number == $c)] | .[0].fields.HasUIChanges // ""')

if [[ "$HAS_UI" != "Yes" ]]; then
  jq -n --argjson card "$CARD" '{card: $card, has_ui: false, requirements: [], missing: [], message: "Not a UI card — skipped"}'
  exit 0
fi

REQUIREMENTS=()
MISSING=()

# ── Check 1: XCUITests exist for the feature ────────────
CARD_SLUG=$(basename /tmp/helix-wt/feature/${CARD}-* 2>/dev/null | head -1 | sed "s/${CARD}-//")
UITEST_DIR="$WORKTREE/helix-appUITests"
UITEST_FILES=""
if [[ -d "$UITEST_DIR" ]]; then
  # Search for tests matching the card slug or related keywords
  UITEST_FILES=$(find "$UITEST_DIR" -name "*.swift" -newer "$WORKTREE/.git/HEAD" 2>/dev/null || true)
  # Also check git diff for new UITest files
  NEW_UITESTS=$(cd "$WORKTREE" && git diff --name-only "origin/$BASE_BRANCH"...HEAD -- 'helix-appUITests/*.swift' 2>/dev/null || true)
fi

if [[ -n "$UITEST_FILES" || -n "$NEW_UITESTS" ]]; then
  REQUIREMENTS+=('{"name": "xcuitests_exist", "status": "pass"}')
else
  REQUIREMENTS+=('{"name": "xcuitests_exist", "status": "fail"}')
  MISSING+=("No XCUITests found for this feature — Builder must write tests in helix-appUITests/")
fi

# ── Check 2: Fixture/seed data exists ───────────────────
# Check if new SwiftData models were added and if fixtures cover them
NEW_MODELS=$(cd "$WORKTREE" && git diff "origin/$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null | grep '^+.*@Model' || true)
HARNESS_CHANGES=$(cd "$WORKTREE" && git diff --name-only "origin/$BASE_BRANCH"...HEAD -- 'Packages/HelixHarness/' 2>/dev/null || true)

if [[ -n "$NEW_MODELS" && -z "$HARNESS_CHANGES" ]]; then
  REQUIREMENTS+=('{"name": "fixture_data", "status": "fail"}')
  MISSING+=("New @Model types added but no fixture/seed data changes in HelixHarness")
elif [[ -n "$HARNESS_CHANGES" ]]; then
  REQUIREMENTS+=('{"name": "fixture_data", "status": "pass"}')
else
  # No new models — check if feature uses existing models that already have fixtures
  REQUIREMENTS+=('{"name": "fixture_data", "status": "pass"}')
fi

# ── Check 3: UITests compile ────────────────────────────
if [[ -n "$UITEST_FILES" || -n "$NEW_UITESTS" ]]; then
  ensure_single_xcodebuild
  BUILD_LOG="/tmp/uitest-compile-${CARD}.log"
  if (cd "$WORKTREE" && xcodebuild build-for-testing \
      -project helix-app.xcodeproj -scheme helix-appUITests \
      -destination 'platform=macOS' -derivedDataPath DerivedData \
      > "$BUILD_LOG" 2>&1); then
    REQUIREMENTS+=('{"name": "uitests_compile", "status": "pass"}')
  else
    REQUIREMENTS+=('{"name": "uitests_compile", "status": "fail"}')
    MISSING+=("XCUITests fail to compile — see $BUILD_LOG")
  fi
else
  REQUIREMENTS+=('{"name": "uitests_compile", "status": "skip"}')
fi

# ── Determine result ─────────────────────────────────────
MISSING_COUNT=${#MISSING[@]}

# ── Output JSON ──────────────────────────────────────────
REQ_JSON=$(printf '%s\n' "${REQUIREMENTS[@]}" | jq -s '.')
MISSING_JSON=$(printf '%s\n' "${MISSING[@]}" | jq -R . | jq -s '.')

jq -n \
  --argjson card "$CARD" \
  --argjson has_ui true \
  --argjson requirements "$REQ_JSON" \
  --argjson missing "$MISSING_JSON" \
  '{card: $card, has_ui: $has_ui, requirements: $requirements, missing: $missing}'
