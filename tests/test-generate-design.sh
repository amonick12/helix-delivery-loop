#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/generate-design.sh"

PASS=0; FAIL=0
assert() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else echo "FAIL: $3 — expected '$2', got '$1'"; FAIL=$((FAIL+1)); fi; }
assert_contains() {
  if echo "$1" | grep -qF -- "$2"; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $3 — output does not contain '$2'"
    FAIL=$((FAIL+1))
  fi
}

# ── Script exists and is executable ─────────────────────
if [[ -x "$SCRIPT" ]]; then
  PASS=$((PASS+1))
else
  echo "FAIL: generate-design.sh is not executable"
  FAIL=$((FAIL+1))
fi

# ── Function existence checks (grep for definitions) ────
check_fn() {
  if grep -qE "^${1}\(\)" "$SCRIPT"; then
    PASS=$((PASS+1))
  else
    echo "FAIL: function $1() not defined in script"
    FAIL=$((FAIL+1))
  fi
}

check_fn "build_app"
check_fn "screenshot_panel"
check_fn "upload_panel"
check_fn "post_panels_comment"
check_fn "set_design_url"
check_fn "queue_design_email"

# ── No legacy references remain ─────────────────────────
LEGACY_LEAK=$(grep -ciE 'stitch|gcloud|googleapis|claude-handoff|api\.anthropic\.com/v1/design' "$SCRIPT" || true)
assert "$LEGACY_LEAK" "0" "no Stitch/gcloud/handoff references in script"

# ── DRY_RUN single issue with two panels ─────────────────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 148 --panels insights-empty,insights-populated --epic 147 2>&1 || true)
assert_contains "$OUTPUT" "Designer mockup capture" "log header present"
assert_contains "$OUTPUT" "Would build helix-app" "DRY_RUN logs build"
assert_contains "$OUTPUT" "Would launch sim with MOCKUP_FIXTURE=insights-empty" "DRY_RUN logs sim launch for first panel"
assert_contains "$OUTPUT" "Would launch sim with MOCKUP_FIXTURE=insights-populated" "DRY_RUN logs sim launch for second panel"
assert_contains "$OUTPUT" "Would upload" "DRY_RUN logs release upload"
assert_contains "$OUTPUT" "Would post panel comment" "DRY_RUN logs comment post"
assert_contains "$OUTPUT" "Would set DesignURL" "DRY_RUN logs DesignURL field"
assert_contains "$OUTPUT" "Would queue design email" "DRY_RUN logs email queue"
assert_contains "$OUTPUT" '"panels": 2' "JSON output reports panel count"

# ── Regenerate requires --resolution-note (G6 guard) ─
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 148 --panels insights-empty --regenerate 2>&1 || true)
assert_contains "$OUTPUT" "requires --resolution-note" "regen without resolution-note rejected"

# ── Regenerate flag with resolution-note (and hash reset so no-change guard doesn't fire) ─
rm -rf /tmp/helix-mockup-hashes
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 148 --panels insights-empty --regenerate --resolution-note "User asked for tighter spacing; edited Mockups/148-insights/InsightsEmpty.swift to use 12pt instead of 16pt between cards." 2>&1 || true)
assert_contains "$OUTPUT" "regenerate=true" "regenerate flag honored"
assert_contains "$OUTPUT" '"regenerated": true' "JSON output reports regenerate"

# ── Regenerate without changes is rejected (P1 #6 guard) ─
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 148 --panels insights-empty --regenerate --resolution-note "still tighter" 2>&1 || true)
assert_contains "$OUTPUT" "byte-identical" "regen guard fires on no-change regen"

# ── Missing args produce errors ─────────────────────────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" 2>&1 || true)
assert_contains "$OUTPUT" "--issue required" "missing --issue error"

OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 148 2>&1 || true)
assert_contains "$OUTPUT" "--panels required" "missing --panels error"

# ── Unknown arg produces error ──────────────────────────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 148 --panels p1 --bogus 2>&1 || true)
assert_contains "$OUTPUT" "Unknown arg" "unknown arg error"

# ── Config loads new mockup constants ───────────────────
source "$SCRIPT_DIR/config.sh"
assert "$MOCKUP_FIXTURE_ENV" "MOCKUP_FIXTURE" "MOCKUP_FIXTURE_ENV set"
assert "$(basename "$MOCKUP_DIR")" "Mockups" "MOCKUP_DIR points at Mockups"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
