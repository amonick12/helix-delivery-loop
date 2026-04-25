#!/bin/bash
# test-audit.sh — meta-test: ensure scripts/audit.sh actually catches the
# contract violations it claims to. For each guarded property, mutate it,
# verify audit fails, restore, verify audit passes.
#
# This stops audit-rot: if a future edit to audit.sh breaks one of the
# regex/file-path checks, this test fails and we know.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AUDIT="$SCRIPT_DIR/audit.sh"

PASS=0; FAIL=0
report_pass() { PASS=$((PASS+1)); }
report_fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Baseline: audit must currently pass.
if bash "$AUDIT" >/dev/null 2>&1; then
  report_pass
else
  report_fail "Baseline audit is failing — fix existing violations before extending the test"
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

# Helper: mutate a file (replace pattern), run audit, expect failure, restore.
expect_fail_after_mutation() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  local replacement="$4"

  if [[ ! -f "$file" ]]; then
    report_fail "$label: target file $file does not exist"
    return
  fi
  cp "$file" "${file}.audit-test-backup"
  # macOS sed -i needs an empty backup suffix.
  if ! sed -i '' "s|${pattern}|${replacement}|" "$file" 2>/dev/null; then
    sed -i "s|${pattern}|${replacement}|" "$file" || true
  fi

  if bash "$AUDIT" >/dev/null 2>&1; then
    report_fail "$label: audit STILL PASSED after mutation — guard is not actually enforced"
  else
    report_pass
  fi

  mv "${file}.audit-test-backup" "$file"
}

# 1. Removing the design email pattern from drain-emails.sh must fail.
expect_fail_after_mutation \
  "drain-design-glob" \
  "$PLUGIN_DIR/scripts/drain-emails.sh" \
  "dead-letter design epic" \
  "dead-letter epic"

# 2. Removing 'epic-final-approved' from dispatcher.sh must fail.
expect_fail_after_mutation \
  "epic-final-approved-routing" \
  "$PLUGIN_DIR/scripts/dispatcher.sh" \
  "epic-final-approved" \
  "epic-final-DISABLED"

# 3. Removing cleanup-epic-mockups invocation from postagent.sh must fail.
expect_fail_after_mutation \
  "cleanup-mockups-from-postagent" \
  "$PLUGIN_DIR/scripts/postagent.sh" \
  "cleanup-epic-mockups.sh" \
  "cleanup-epic-mockups-DISABLED.sh"

# 4. Removing queue_dead_letter_email from postagent.sh must fail.
expect_fail_after_mutation \
  "dead-letter-email-queue" \
  "$PLUGIN_DIR/scripts/postagent.sh" \
  "queue_dead_letter_email" \
  "queue_dead_letter_email_DISABLED"

# 5. Removing 'BEFORE invoking' ordering from agent-designer.md must fail.
expect_fail_after_mutation \
  "designer-mockup-ordering" \
  "$PLUGIN_DIR/references/agent-designer.md" \
  "BEFORE invoking" \
  "WHENEVER"

# 6. Removing 'docs/product-vision.md' from agent-scout.md must fail.
expect_fail_after_mutation \
  "scout-vision-doc-read" \
  "$PLUGIN_DIR/references/agent-scout.md" \
  "docs/product-vision.md" \
  "docs/random-doc.md"

# 7. Removing 'Quality bar' from agent-designer.md must fail.
expect_fail_after_mutation \
  "designer-quality-bar" \
  "$PLUGIN_DIR/references/agent-designer.md" \
  "## Quality bar" \
  "## Random Section"

# 8. Removing 'vision_qa_passed' from generate-design.sh must fail.
expect_fail_after_mutation \
  "vision-qa-flag-design" \
  "$PLUGIN_DIR/scripts/generate-design.sh" \
  "vision_qa_passed:false" \
  "qa_disabled:false"

# 9. Removing the vision-QA gate handlers from drain-emails.sh must fail.
expect_fail_after_mutation \
  "stage-a-gate" \
  "$PLUGIN_DIR/scripts/drain-emails.sh" \
  "mark-vision-pass" \
  "mark-disabled"

# 10. Removing the Gmail-MCP sentinel handler from drain-emails.sh must fail.
expect_fail_after_mutation \
  "gmail-mcp-sentinel" \
  "$PLUGIN_DIR/scripts/drain-emails.sh" \
  "GMAIL_DOWN_SENTINEL" \
  "DISABLED_SENTINEL"

# 11. Removing AUTODEV_LOCK from cleanup-epic-mockups.sh must fail.
expect_fail_after_mutation \
  "autodev-lock" \
  "$PLUGIN_DIR/scripts/cleanup-epic-mockups.sh" \
  "AUTODEV_LOCK" \
  "DISABLED_LOCK"

# 12. Removing EC-7 from postagent.sh must fail.
expect_fail_after_mutation \
  "ec-7-planner-zero-subcards" \
  "$PLUGIN_DIR/scripts/postagent.sh" \
  "EC-7" \
  "EC-DISABLED"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
