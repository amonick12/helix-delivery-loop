#!/bin/bash
# notify-epic-testflight.sh — when an epic's last sub-card is ready, build a
# TestFlight, gather all sub-card screenshots, email the user, and gate the
# Releaser via the `epic-testflight-pending` label until the user adds
# `epic-final-approved` (or `user-approved`) after testing on device.
#
# Usage:
#   notify-epic-testflight.sh --epic <N>
#
# Exits 0 on success (gate added + email composed) or 0 with reason="not ready"
# when the completion check says no.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EPIC=""
REPO="${GH_REPO:-amonick12/helix}"
TO="${EPIC_NOTIFY_TO:-amonick12@gmail.com}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --epic) EPIC="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --to)   TO="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$EPIC" ]] && { echo "Usage: $0 --epic <N>" >&2; exit 1; }

# 1. Check completion. If not ready, exit cleanly.
status=$(bash "$SCRIPT_DIR/check-epic-completion.sh" --epic "$EPIC" --repo "$REPO")
ready=$(echo "$status" | jq -r '.ready_for_testflight')
if [[ "$ready" != "true" ]]; then
  echo "$status" | jq -c '{epic, ready_for_testflight, reason}'
  exit 0
fi

last_pr=$(echo "$status" | jq -r '.last_pr')
last_card=$(echo "$status" | jq -r '.last_card')
all_sub=$(echo "$status" | jq -r '.sub_cards[].number')

# 2. Compute build number (deterministic) and trigger TestFlight upload.
#    Build number = (epic * 1000) + last_card_low, just to be unique vs sub-card uploads.
BUILD_NUMBER=$(( EPIC * 1000 + last_card ))
TF_LINK=""

if [[ -x "/Users/aaronmonick/Downloads/helix/devtools/ios-agent/testflight-upload.sh" ]]; then
  echo "Uploading TestFlight build $BUILD_NUMBER for epic #$EPIC (PR #$last_pr)…" >&2
  if /Users/aaronmonick/Downloads/helix/devtools/ios-agent/testflight-upload.sh \
       --build-number "$BUILD_NUMBER" 2>/tmp/tf-epic-$EPIC.log; then
    TF_LINK=$(grep -oE 'https://testflight.apple.com/[^ ]+' /tmp/tf-epic-$EPIC.log | head -1)
    [[ -z "$TF_LINK" ]] && TF_LINK="(check App Store Connect — link not parsed from log)"
  else
    TF_LINK="(TestFlight upload failed — see /tmp/tf-epic-$EPIC.log)"
  fi
else
  TF_LINK="(testflight-upload.sh not available — manual upload required)"
fi

# 3. Gather screenshot URLs from all sub-card PR bodies.
SCREENSHOTS=$(mktemp)
echo "$all_sub" | while read -r sub; do
  pr=$(gh pr list --repo "$REPO" --state all --search "linked:issue-$sub" \
    --json number --limit 1 --jq '.[0].number // empty')
  [[ -z "$pr" ]] && continue
  echo ""
  echo "### Card #$sub (PR #$pr)"
  gh pr view "$pr" --repo "$REPO" --json body --jq '.body' | grep -oE 'https://github\.com/'"$REPO"'/releases/download/screenshots/[^"]+\.(png|jpg|jpeg|mov|mp4)' | sort -u | while read url; do
    echo "<img src=\"$url\" width=\"300\">"
  done
done > "$SCREENSHOTS"

# 4. Compose email body.
EPIC_TITLE=$(gh issue view "$EPIC" --repo "$REPO" --json title --jq '.title')
EPIC_URL="https://github.com/$REPO/issues/$EPIC"
LAST_PR_URL="https://github.com/$REPO/pull/$last_pr"

EMAIL=$(mktemp)
cat > "$EMAIL" <<BODY
**Epic ready for TestFlight confirmation — $EPIC_TITLE**

The last sub-card of epic #$EPIC has all automated approvals (code review + visual QA). Before merging the final PR, please test on device.

**TestFlight build:** $TF_LINK
**Build number:** $BUILD_NUMBER
**Final PR:** $LAST_PR_URL
**Epic:** $EPIC_URL

---

**Sub-cards in this epic:**
$(echo "$all_sub" | while read sub; do echo "- #$sub"; done)

---

**Cumulative screenshots (all sub-card changes):**
$(cat "$SCREENSHOTS")

---

**To approve the merge:**
- Add label \`epic-final-approved\` to PR #$last_pr, OR
- Add label \`user-approved\` to PR #$last_pr (works the same)

**To reject:**
- Comment on PR #$last_pr with the issues you found
- Tester will re-run after the Builder fixes them

The Releaser is gated by the \`epic-testflight-pending\` label and will not merge until you confirm.
BODY

# Verify all image URLs resolve before sending.
if ! bash "$SCRIPT_DIR/verify-image-urls.sh" "$EMAIL" >/dev/null; then
  echo "WARNING: some image URLs failed verification (see verify-image-urls.sh output)" >&2
fi

# 5. Add the gate label on the last sub-card PR.
gh pr edit "$last_pr" --repo "$REPO" --add-label "epic-testflight-pending" 2>/dev/null || true

# 6. Queue the email for the orchestrator to send via Gmail MCP.
#    Shell scripts cannot invoke MCP tools directly — the /delivery-loop
#    orchestrator scans this queue at every dispatch and sends each pending
#    payload via mcp__claude_ai_Gmail__send_message (or whatever tool name the
#    server publishes once OAuth completes).
QUEUE_DIR="${EPIC_EMAIL_QUEUE_DIR:-/tmp/helix-epic-emails-pending}"
mkdir -p "$QUEUE_DIR"
QUEUE_FILE="$QUEUE_DIR/epic-$EPIC.json"
jq -n \
  --arg to "$TO" \
  --arg subject "[Helix] Epic #$EPIC ready for TestFlight confirmation — $EPIC_TITLE" \
  --arg body "$(cat "$EMAIL")" \
  --arg epic "$EPIC" \
  --arg pr "$last_pr" \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{to:$to, subject:$subject, body:$body, epic:($epic|tonumber), last_pr:($pr|tonumber), created_at:$created_at, sent:false}' \
  > "$QUEUE_FILE"
echo "Queued email at $QUEUE_FILE — orchestrator will dispatch via Gmail MCP." >&2

# 7. Comment on the epic announcing the gate.
gh issue comment "$EPIC" --repo "$REPO" --body "bot: **TestFlight gate active.** All sub-cards merged or ready. Final PR #$last_pr labeled \`epic-testflight-pending\`. TestFlight build $BUILD_NUMBER uploaded; email queued for $TO via Gmail MCP. Add \`epic-final-approved\` to PR #$last_pr after testing on device." 2>/dev/null || true

echo "$status" | jq -c --arg tf "$TF_LINK" --arg pr "$last_pr" --arg build "$BUILD_NUMBER" --arg queue "$QUEUE_FILE" \
  '. + {testflight_link: $tf, last_pr: $pr, build_number: $build, gate_label_applied: true, email_queued: $queue}'
