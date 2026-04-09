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

check_fn "get_stitch_token"
check_fn "stitch_api_call"
check_fn "generate_screen_from_text"
check_fn "edit_screen"
check_fn "extract_download_urls"
check_fn "download_mockup"
check_fn "post_mockup_to_issue"
check_fn "check_design_completeness"
check_fn "process_issue"
check_fn "build_prompt_from_card"

# ── Argument parsing: --issue + --prompt (DRY_RUN) ──────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 148 --prompt "Test prompt for insights" 2>&1 || true)
assert_contains "$OUTPUT" "Processing issue #148" "arg parse --issue --prompt"
assert_contains "$OUTPUT" "DRY_RUN" "DRY_RUN mode active with --issue --prompt"

# ── Argument parsing: --from-card (DRY_RUN) ─────────────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 148 --from-card 2>&1 || true)
assert_contains "$OUTPUT" "Processing issue #148" "arg parse --issue --from-card"
assert_contains "$OUTPUT" "DRY_RUN" "DRY_RUN mode active with --from-card"

# ── Argument parsing: --base-screen (DRY_RUN) ───────────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 148 --prompt "Edit insights" --base-screen insights-tab 2>&1 || true)
assert_contains "$OUTPUT" "Processing issue #148" "arg parse --base-screen"

# ── Argument parsing: --batch (DRY_RUN) ─────────────────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --batch 146,147,148 2>&1 || true)
assert_contains "$OUTPUT" "Batch mode" "arg parse --batch"
assert_contains "$OUTPUT" "Processing issue #146" "batch processes 146"
assert_contains "$OUTPUT" "Processing issue #147" "batch processes 147"
assert_contains "$OUTPUT" "Processing issue #148" "batch processes 148"
assert_contains "$OUTPUT" "Batch complete" "batch completion message"

# ── Missing --issue errors ──────────────────────────────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --prompt "Test" 2>&1 || true)
assert_contains "$OUTPUT" "is required" "missing --issue error"

# ── DRY_RUN skips API calls ────────────────────────────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --issue 99 --prompt "Test" 2>&1 || true)
assert_contains "$OUTPUT" "[DRY_RUN] Would POST to" "DRY_RUN logs API call"
assert_contains "$OUTPUT" "[DRY_RUN] Would download" "DRY_RUN logs download"
assert_contains "$OUTPUT" "[DRY_RUN] Would post mockup comment" "DRY_RUN logs issue comment"
assert_contains "$OUTPUT" "[DRY_RUN] Would set DesignURL" "DRY_RUN logs field update"

# ── Unknown arg produces error ──────────────────────────
OUTPUT=$(DRY_RUN=1 bash "$SCRIPT" --bogus 2>&1 || true)
assert_contains "$OUTPUT" "Unknown arg" "unknown arg error"

# ── Config values sourced correctly ─────────────────────
assert_contains "$(grep 'STITCH_MCP_URL' "$SCRIPT_DIR/config.sh")" "stitch.googleapis.com" "config has Stitch URL"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
