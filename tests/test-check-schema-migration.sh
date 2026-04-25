#!/bin/bash
# Tests check-schema-migration.sh by building tiny ephemeral git repos that
# simulate diffs against an autodev base, then asserting the script's pass/fail.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/check-schema-migration.sh"

PASS=0; FAIL=0
report_pass() { PASS=$((PASS+1)); }
report_fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ── Build a fake repo with a HelixPersistence layout ────
build_repo() {
  local dir="$1"
  rm -rf "$dir"
  git init -q "$dir"
  cd "$dir"
  git config user.email t@t
  git config user.name t
  mkdir -p Packages/HelixPersistence/Sources/HelixPersistence/Models
  cat > Packages/HelixPersistence/Sources/HelixPersistence/Models/JournalEntry.swift <<'EOF'
import SwiftData
@Model
class JournalEntry {
    var title: String = ""
}
EOF
  cat > Packages/HelixPersistence/Sources/HelixPersistence/HelixModelSchema.swift <<'EOF'
import SwiftData
enum HelixModelSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] = [JournalEntry.self]
}
EOF
  git add . >/dev/null
  git commit -qm "init"
  git checkout -qb autodev
  git branch -q -M autodev
  # Create origin/autodev for the script's base reference
  git remote add origin "$dir/.git" 2>/dev/null || true
  git update-ref refs/remotes/origin/autodev HEAD
  git checkout -qb feature/test
}

# ── Case 1: no schema diff → pass ───────────────────────
TMP1=$(mktemp -d)
build_repo "$TMP1"
echo "// unrelated change" >> Packages/HelixPersistence/Sources/HelixPersistence/Models/JournalEntry.swift
git add . >/dev/null && git commit -qm "non-schema"
set +e; bash "$SCRIPT" --worktree "$TMP1" --base autodev >/dev/null 2>&1; RC=$?; set -e
[[ "$RC" == "0" ]] && report_pass || report_fail "Case 1 no-schema-diff: expected 0, got $RC"

# ── Case 2: @Model field added without migration → fail ──
TMP2=$(mktemp -d)
build_repo "$TMP2"
sed -i.bak 's|var title: String = ""|var title: String = ""\
    var subtitle: String = ""|' Packages/HelixPersistence/Sources/HelixPersistence/Models/JournalEntry.swift
rm Packages/HelixPersistence/Sources/HelixPersistence/Models/JournalEntry.swift.bak
git add . >/dev/null && git commit -qm "add field"
set +e; bash "$SCRIPT" --worktree "$TMP2" --base autodev >/dev/null 2>&1; RC=$?; set -e
[[ "$RC" == "1" ]] && report_pass || report_fail "Case 2 added field no-migration: expected 1, got $RC"

# ── Case 3: @Model field added with migration → pass ────
TMP3=$(mktemp -d)
build_repo "$TMP3"
sed -i.bak 's|var title: String = ""|var title: String = ""\
    var subtitle: String = ""|' Packages/HelixPersistence/Sources/HelixPersistence/Models/JournalEntry.swift
rm Packages/HelixPersistence/Sources/HelixPersistence/Models/JournalEntry.swift.bak
cat > Packages/HelixPersistence/Sources/HelixPersistence/HelixModelSchema.swift <<'EOF'
import SwiftData
enum HelixModelSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] = [JournalEntry.self]
}
enum HelixModelSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] = [JournalEntry.self]
}
enum HelixMigrationPlan: SchemaMigrationPlan {
    static var stages: [MigrationStage] = [
        MigrationStage.lightweight(fromVersion: HelixModelSchemaV1.self, toVersion: HelixModelSchemaV2.self)
    ]
}
EOF
git add . >/dev/null && git commit -qm "add field with migration"
set +e; bash "$SCRIPT" --worktree "$TMP3" --base autodev >/dev/null 2>&1; RC=$?; set -e
[[ "$RC" == "0" ]] && report_pass || report_fail "Case 3 added field with-migration: expected 0, got $RC"

# Cleanup
rm -rf "$TMP1" "$TMP2" "$TMP3"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
