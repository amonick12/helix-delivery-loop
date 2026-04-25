#!/bin/bash
# Tests trace.sh's event aggregation.
# Network-touching parts (gh issue events, gh pr events) are skipped via
# DRY_RUN=1; we exercise the local parts: state, dispatch-log, queue files.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/trace.sh"

PASS=0; FAIL=0
report_pass() { PASS=$((PASS+1)); }
report_fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
assert_contains() {
  if echo "$1" | grep -qF -- "$2"; then
    PASS=$((PASS+1))
  else
    echo "FAIL: $3 — output does not contain '$2'"
    FAIL=$((FAIL+1))
  fi
}

# ── Help works ──────────────────────────────────────────
OUT=$(bash "$SCRIPT" --help 2>&1 || true)
assert_contains "$OUT" "trace.sh" "help present"

# ── Missing --card errors ───────────────────────────────
set +e; bash "$SCRIPT" >/dev/null 2>&1; RC=$?; set -e
[[ "$RC" -ne 0 ]] && report_pass || report_fail "missing --card should error"

# ── Empty card (no events) renders ──────────────────────
TMP_STATE=$(mktemp)
echo '{"cards":{}}' > "$TMP_STATE"
TMP_QUEUE=$(mktemp -d)
OUT=$(STATE_FILE="$TMP_STATE" EPIC_EMAIL_QUEUE_DIR="$TMP_QUEUE" DRY_RUN=1 bash "$SCRIPT" --card 999999 2>&1 || true)
assert_contains "$OUT" "Card #999999 timeline" "empty card renders timeline header"

# ── JSON output ─────────────────────────────────────────
OUT=$(STATE_FILE="$TMP_STATE" EPIC_EMAIL_QUEUE_DIR="$TMP_QUEUE" DRY_RUN=1 bash "$SCRIPT" --card 999999 --json 2>&1 || true)
echo "$OUT" | jq -e '.card and .events' >/dev/null 2>&1 && report_pass || report_fail "JSON output is malformed"

# ── Email queue file shows in trace ─────────────────────
cat > "$TMP_QUEUE/design-999999.json" <<'EOF'
{"to":"u@example.com","subject":"[Helix] Epic #999999 ready","body":"...","card":999999,"kind":"design","created_at":"2026-04-24T12:00:00Z","sent":false,"vision_qa_passed":false}
EOF
OUT=$(STATE_FILE="$TMP_STATE" EPIC_EMAIL_QUEUE_DIR="$TMP_QUEUE" DRY_RUN=1 bash "$SCRIPT" --card 999999 2>&1 || true)
assert_contains "$OUT" "EMAIL" "trace shows EMAIL row for queued email"
assert_contains "$OUT" "design" "trace surfaces email kind"

# Cleanup
rm -rf "$TMP_QUEUE" "$TMP_STATE"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
