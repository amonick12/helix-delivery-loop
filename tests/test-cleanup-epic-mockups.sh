#!/bin/bash
# Tests cleanup-epic-mockups.sh against synthetic epic directories.
# Uses DRY_RUN to avoid touching the real helix-app build/git.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/cleanup-epic-mockups.sh"

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

source "$SCRIPT_DIR/config.sh"

# ── No-op when no dir + no registration line ────────────
OUT=$(DRY_RUN=1 bash "$SCRIPT" --epic 88888 2>&1 || true)
assert_contains "$OUT" "nothing to remove on disk" "no-op when missing dir warns"
assert_contains "$OUT" '"status": "cleaned"' "no-op JSON status cleaned"

# ── Removes synthetic epic dir + registration line ──────
EPIC=88889
EPIC_DIR="$MOCKUP_DIR/${EPIC}-test"
mkdir -p "$EPIC_DIR"
cat > "$EPIC_DIR/Panel.swift" <<EOF
import SwiftUI
struct ${EPIC}TestMockup: View { var body: some View { Text("hi") } }
EOF
# Append a registration line so the strip can find it
cat >> "$MOCKUP_REGISTRY_FILE" <<EOF

panels += Epic${EPIC}Mockups.panels
EOF

OUT=$(DRY_RUN=1 bash "$SCRIPT" --epic "$EPIC" 2>&1 || true)
assert_contains "$OUT" "Would remove 'panels += Epic${EPIC}Mockups.panels'" "DRY_RUN logs strip"
assert_contains "$OUT" "Would rm -rf $EPIC_DIR" "DRY_RUN logs dir removal"

# Cleanup the test mutations to MOCKUP_REGISTRY_FILE + dir
rm -rf "$EPIC_DIR"
# Strip the line we appended so we don't pollute the registry
TMP_REG=$(mktemp)
grep -vE "panels\s*\+=\s*Epic${EPIC}Mockups\.panels" "$MOCKUP_REGISTRY_FILE" > "$TMP_REG"
mv "$TMP_REG" "$MOCKUP_REGISTRY_FILE"

# ── In-use struct preserves the dir ─────────────────────
EPIC=88890
EPIC_DIR="$MOCKUP_DIR/${EPIC}-keep"
mkdir -p "$EPIC_DIR"
# Swift struct names must start with a letter, so name them Epic<N>Foo
cat > "$EPIC_DIR/InUse.swift" <<EOF
import SwiftUI
struct EpicKeepInUseMockup: View { var body: some View { Text("hi") } }
EOF
# Reference it from a fake shipping file outside Mockups/
TEMP_SHIPPING="$HELIX_REPO_ROOT/helix-app/_TempUse.swift"
cat > "$TEMP_SHIPPING" <<EOF
import SwiftUI
let _x: EpicKeepInUseMockup = EpicKeepInUseMockup()
EOF
# Register it so the strip path also sees the in-use signal
cat >> "$MOCKUP_REGISTRY_FILE" <<EOF

panels += Epic${EPIC}Mockups.panels
EOF

OUT=$(DRY_RUN=1 bash "$SCRIPT" --epic "$EPIC" 2>&1 || true)
assert_contains "$OUT" "Keeping InUse.swift" "in-use file is preserved"
assert_contains "$OUT" "Preserving Epic${EPIC}Mockups registration" "in-use registration preserved"

rm -f "$TEMP_SHIPPING"
rm -rf "$EPIC_DIR"
# Strip the registration we appended
TMP_REG=$(mktemp)
grep -vE "panels\s*\+=\s*Epic${EPIC}Mockups\.panels" "$MOCKUP_REGISTRY_FILE" > "$TMP_REG"
mv "$TMP_REG" "$MOCKUP_REGISTRY_FILE"

# ── Lock function defined ───────────────────────────────
if grep -qE 'acquire_autodev_lock\(\)' "$SCRIPT" && grep -qE 'release_autodev_lock\(\)' "$SCRIPT"; then
  PASS=$((PASS+1))
else
  echo "FAIL: acquire_autodev_lock / release_autodev_lock not defined"
  FAIL=$((FAIL+1))
fi
# Lock is mkdir-based (consistent with simulator lock pattern)
if grep -qE 'mkdir "\$AUTODEV_LOCK"' "$SCRIPT"; then
  PASS=$((PASS+1))
else
  echo "FAIL: AUTODEV_LOCK should be mkdir-based"
  FAIL=$((FAIL+1))
fi

# ── --epic missing fails ────────────────────────────────
set +e
DRY_RUN=1 bash "$SCRIPT" >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] && PASS=$((PASS+1)) || { echo "FAIL: missing --epic should error"; FAIL=$((FAIL+1)); }

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
