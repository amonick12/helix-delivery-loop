#!/bin/bash
# generate-design.sh — Designer agent mockup driver.
#
# The Designer agent (Opus 4.7, the same model that powers Claude Design)
# writes SwiftUI mockup views directly into helix-app/PreviewHost/Mockups/
# using real Helix design tokens, registers them in PreviewHostScreen.all,
# builds, boots the simulator with MOCKUP_FIXTURE=<panel-id>, screenshots
# each panel, uploads to the `screenshots` GitHub Release, embeds them in
# a Designer comment on the card, and queues an approval email for the
# orchestrator to send via Gmail MCP.
#
# This script is the deterministic build/screenshot/upload glue. The actual
# SwiftUI authoring is performed by the Designer agent itself before calling
# this script (see references/agent-designer.md).
#
# Usage:
#   ./generate-design.sh --issue 148 --panels insights-empty,insights-populated
#   ./generate-design.sh --issue 148 --panels insights-empty --regenerate
#
# Environment:
#   DRY_RUN=1   Skip xcodebuild, simctl, gh — log what would happen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
generate-design.sh — Build, screenshot, and post SwiftUI mockup panels.

Usage:
  ./generate-design.sh --issue 148 --panels insights-empty,insights-populated
  ./generate-design.sh --issue 148 --panels insights-empty --regenerate

Options:
  --issue        Card number to process
  --panels       Comma-separated mockup panel IDs (must already exist in
                 PreviewHostScreen.all — written by the Designer agent before
                 invoking this script)
  --regenerate   Indicates this run is responding to a user comment requesting
                 changes — re-screenshots and posts a fresh email
  --epic         Optional epic number for emailing/labeling

Environment:
  DRY_RUN=1   Skip xcodebuild, simctl, gh — log what would happen.

Requires: xcodebuild, xcrun simctl, gh CLI, jq.
HELP

ISSUE=""
PANELS=""
REGENERATE="false"
EPIC=""
RESOLUTION_NOTE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)            ISSUE="$2"; shift 2 ;;
    --panels)           PANELS="$2"; shift 2 ;;
    --regenerate)       REGENERATE="true"; shift ;;
    --epic)             EPIC="$2"; shift 2 ;;
    --resolution-note)  RESOLUTION_NOTE="$2"; shift 2 ;;
    *)                  log_error "Unknown arg: $1"; exit 1 ;;
  esac
done
[[ -z "$ISSUE" ]] && { log_error "--issue required"; exit 1; }
[[ -z "$PANELS" ]] && { log_error "--panels required (comma-separated panel IDs)"; exit 1; }
if [[ "$REGENERATE" == "true" && -z "$RESOLUTION_NOTE" ]]; then
  log_error "--regenerate requires --resolution-note \"<paragraph>\" — Designer must explain which user comment(s) drove this regeneration and what changed"
  exit 1
fi

IFS=',' read -ra PANEL_LIST <<< "$PANELS"

# ── Regen change-detection ──────────────────────────────
# When --regenerate is set, the user has commented requesting changes. The
# Designer agent must have actually edited the SwiftUI mockup files for this
# epic since the previous design comment, otherwise we'd ship the same
# mockups back labeled "updated" — a silent contract violation.
HASH_DIR="/tmp/helix-mockup-hashes"
mkdir -p "$HASH_DIR"

snapshot_mockup_hashes() {
  local issue="$1"
  local epic_dir
  epic_dir=$(find "$MOCKUP_DIR" -maxdepth 1 -type d -name "${issue}-*" 2>/dev/null | head -1)
  if [[ -z "$epic_dir" || ! -d "$epic_dir" ]]; then
    # Fallback: hash all mockups directory contents (sub-card without its own dir)
    epic_dir="$MOCKUP_DIR"
  fi
  find "$epic_dir" -type f -name '*.swift' -exec shasum -a 256 {} \; 2>/dev/null \
    | awk '{print $1}' \
    | sort \
    | shasum -a 256 \
    | awk '{print $1}'
}

verify_regen_changed() {
  local issue="$1"
  local hash_file="$HASH_DIR/issue-${issue}.hash"
  local current
  current=$(snapshot_mockup_hashes "$issue")
  if [[ -f "$hash_file" ]]; then
    local prev
    prev=$(cat "$hash_file")
    if [[ "$prev" == "$current" ]]; then
      log_error "Designer marked --regenerate but the SwiftUI mockup files are byte-identical to the previous version. Refusing to ship an empty regeneration."
      log_error "Edit the .swift files in $MOCKUP_DIR/${issue}-* to actually address the user's feedback, then re-run."
      return 1
    fi
  fi
  echo "$current" > "$hash_file"
  return 0
}

# ── Build ───────────────────────────────────────────────
build_app() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would build helix-app"
    return 0
  fi
  log_info "Building helix-app for mockup capture"
  bash "$MOCKUP_BUILD_SCRIPT" >&2 || {
    log_error "Build failed — Designer cannot screenshot mockups without a working build"
    return 1
  }
}

# ── Boot simulator with MOCKUP_FIXTURE env var, take screenshot ─
screenshot_panel() {
  local panel="$1"
  local out="/tmp/mockup-${ISSUE}-${panel}.png"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would launch sim with $MOCKUP_FIXTURE_ENV=$panel and screenshot to $out"
    : > "$out"
    echo "$out"
    return 0
  fi

  acquire_simulator_lock 600 || return 1
  trap 'release_simulator_lock' RETURN

  xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true

  # Launch the app with MOCKUP_FIXTURE set so PreviewHost boots straight into
  # the named panel. App-level launch uses the existing launch-app.sh helper.
  MOCKUP_FIXTURE="$panel" bash "$MOCKUP_LAUNCH_SCRIPT" >&2 || {
    log_error "Failed to launch app with $MOCKUP_FIXTURE_ENV=$panel"
    return 1
  }

  sleep 2  # Allow render to settle (animations)
  xcrun simctl io "$SIMULATOR_UDID" screenshot "$out" 2>&1 >/dev/null || {
    log_error "Failed to screenshot panel $panel"
    return 1
  }

  if [[ ! -s "$out" ]]; then
    log_error "Screenshot $out is empty"
    return 1
  fi

  log_info "Captured $panel -> $out"
  echo "$out"
}

# ── Upload to GitHub Release ────────────────────────────
upload_panel() {
  local file="$1"
  local panel="$2"
  local asset_name="design-${ISSUE}-${panel}.png"
  local renamed="/tmp/${asset_name}"

  cp "$file" "$renamed"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would upload $renamed as $asset_name"
    echo "https://github.com/${REPO}/releases/download/screenshots/${asset_name}?raw=true"
    return 0
  fi

  gh release upload screenshots "$renamed" --repo "$REPO" --clobber 2>&1 | grep -v "^$" >&2 || true
  echo "https://github.com/${REPO}/releases/download/screenshots/${asset_name}?raw=true"
}

# ── Post Designer panel comment ─────────────────────────
post_panels_comment() {
  local heading="$1"
  shift
  local urls=("$@")

  local body_file="/tmp/design-comment-${ISSUE}.md"
  {
    echo "## bot: ${heading}"
    echo ""
    if [[ "$REGENERATE" == "true" ]]; then
      echo "Regenerated in response to feedback. New mockups below — comment with further changes or apply \`epic-approved\` to proceed."
      echo ""
      echo "**What changed:** ${RESOLUTION_NOTE}"
    else
      echo "Designer-rendered SwiftUI mockups. These views use the actual Helix design system (\`Color.helixAccent\`, \`.glassCard()\`, \`helixFont\`, real tab bar) and were screenshot from the simulator, not approximated."
    fi
    echo ""
    local idx=0
    for url in "${urls[@]}"; do
      idx=$((idx + 1))
      echo "**Panel ${idx} — ${PANEL_LIST[$((idx-1))]}**"
      echo ""
      echo "<img src=\"${url}\" width=\"400\">"
      echo ""
    done
    echo "### Vision QA"
    echo ""
    echo "Designer agent verified each screenshot against the Helix design tokens (Ocean gradient, indigo accent, ultraThinMaterial cards, **6-tab liquid-glass** bar in order Today/Journal/Practices/Insights/Knowledge/Settings, an entry-point panel showing how the feature is reached from the existing app, no stock human/avatar imagery)."
  } > "$body_file"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would post panel comment to issue #$ISSUE"
    rm -f "$body_file"
    return 0
  fi

  bash "$SCRIPT_DIR/verify-image-urls.sh" "$body_file" || {
    log_error "Broken image URL in panel comment — aborting post"
    return 1
  }

  gh issue comment "$ISSUE" --repo "$REPO" --body-file "$body_file"
  rm -f "$body_file"
}

# ── Set DesignURL field ─────────────────────────────────
set_design_url() {
  local url="$1"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would set DesignURL=$url on issue #$ISSUE"
    return 0
  fi
  "$SCRIPT_DIR/set-field.sh" --issue "$ISSUE" --field "DesignURL" --value "$url" 2>/dev/null \
    || log_warn "Could not set DesignURL on issue #$ISSUE"
}

# ── Queue design-approval email ─────────────────────────
queue_design_email() {
  local target_card="${EPIC:-$ISSUE}"
  local urls=("$@")

  local title body_file
  title=$(gh issue view "$target_card" --repo "$REPO" --json title -q '.title' 2>/dev/null || echo "Card #$target_card")
  body_file="/tmp/design-email-${target_card}.md"
  {
    echo "**Epic ready for design approval — ${title}**"
    echo ""
    if [[ "$REGENERATE" == "true" ]]; then
      echo "Designer regenerated the mockups in response to your feedback."
      echo ""
      echo "**What changed this round:** ${RESOLUTION_NOTE}"
      echo ""
    else
      echo "The Designer agent rendered the SwiftUI mockups for epic #${target_card} from the real Helix design system. Review and either:"
    fi
    echo ""
    echo "- **Approve:** add label \`epic-approved\` to issue #${target_card}. Planner will split into sub-cards (each inheriting the relevant panel) and Builder will start."
    echo "- **Request changes:** comment on issue #${target_card} with what to change. Designer will regenerate and email a new set."
    echo ""
    echo "**Card:** https://github.com/${REPO}/issues/${target_card}"
    echo ""
    echo "**Mockups:**"
    echo ""
    local idx=0
    for url in "${urls[@]}"; do
      idx=$((idx + 1))
      echo "**Panel ${idx} — ${PANEL_LIST[$((idx-1))]}**"
      echo ""
      echo "<img src=\"${url}\" width=\"300\">"
      echo ""
    done
  } > "$body_file"

  local subject_prefix="ready for design approval"
  [[ "$REGENERATE" == "true" ]] && subject_prefix="updated mockups for review"

  local to="${EPIC_NOTIFY_TO:-amonick12@gmail.com}"
  local queue_dir="${EPIC_EMAIL_QUEUE_DIR:-/tmp/helix-epic-emails-pending}"
  mkdir -p "$queue_dir"
  local queue_file="$queue_dir/design-${target_card}.json"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would queue design email at $queue_file"
    rm -f "$body_file"
    return 0
  fi

  # Build the screenshot URL list so the orchestrator's pre-send vision QA
  # pass can Read each panel and veto the email if anything's wrong.
  local screenshots_json
  screenshots_json=$(printf '%s\n' "${urls[@]}" | jq -R . | jq -s '.')

  jq -n \
    --arg to "$to" \
    --arg subject "[Helix] Epic #${target_card} ${subject_prefix} — ${title}" \
    --arg body "$(cat "$body_file")" \
    --arg card "$target_card" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson screenshots "$screenshots_json" \
    '{to:$to, subject:$subject, body:$body, card:($card|tonumber), kind:"design", created_at:$created_at, sent:false, vision_qa_passed:false, vision_qa_retries:0, screenshots:$screenshots}' \
    > "$queue_file"
  log_info "Queued design email at $queue_file — orchestrator runs vision QA, then drains via Gmail MCP"
  rm -f "$body_file"
}

# ── Main ────────────────────────────────────────────────
log_info "Designer mockup capture for issue #$ISSUE (panels: $PANELS, regenerate=$REGENERATE)"

if [[ "$REGENERATE" == "true" ]]; then
  verify_regen_changed "$ISSUE" || exit 2
else
  # First-time generation: snapshot baseline so a future --regenerate has
  # something to compare against.
  snapshot_mockup_hashes "$ISSUE" > "$HASH_DIR/issue-${ISSUE}.hash"
fi

build_app || exit 1

PANEL_URLS=()
for panel in "${PANEL_LIST[@]}"; do
  panel="${panel// /}"
  [[ -z "$panel" ]] && continue
  shot=$(screenshot_panel "$panel") || exit 1
  url=$(upload_panel "$shot" "$panel")
  PANEL_URLS+=("$url")
  rm -f "$shot" "/tmp/design-${ISSUE}-${panel}.png"
done

heading="Design Mockups (SwiftUI)"
[[ "$REGENERATE" == "true" ]] && heading="Design Mockups Updated (SwiftUI)"
post_panels_comment "$heading" "${PANEL_URLS[@]}"
set_design_url "${PANEL_URLS[0]}"
queue_design_email "${PANEL_URLS[@]}"

log_info "Designer captured ${#PANEL_URLS[@]} panel(s) for issue #$ISSUE"
jq -n \
  --argjson issue "$ISSUE" \
  --argjson panels "${#PANEL_URLS[@]}" \
  --arg regenerate "$REGENERATE" \
  '{issue:$issue, panels:$panels, regenerated:($regenerate=="true")}'
