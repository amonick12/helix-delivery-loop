#!/bin/bash
# check-schema-migration.sh — block merges that change SwiftData @Model
# without a corresponding migration plan.
#
# A new @Model field, removed field, or type change requires a SwiftData
# migration. Without one, first-launch-after-update on real devices crashes
# and the user has to wipe their data — silent corruption that unit tests
# on a fresh container won't catch.
#
# Heuristic check: if the diff against autodev touches any file under
# Packages/HelixPersistence/ and adds/removes a `@Attribute(...)`,
# `@Relationship(...)`, or `@Model` decoration, AND HelixModelSchema.swift's
# `versionedSchema` count or migration plan didn't change accordingly,
# fail with a P0.
#
# Usage:
#   ./check-schema-migration.sh --worktree <path> [--base autodev]
#
# Exit:
#   0 — no schema-affecting change, OR change is paired with a migration
#   1 — schema-affecting change without migration plan update

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
check-schema-migration.sh — block merges that change @Model without a migration.

Usage:
  ./check-schema-migration.sh --worktree <path> [--base autodev]

Reports JSON: { worktree, schema_files_changed, migration_updated, ok, reasons[] }
HELP

WORKTREE=""
BASE="autodev"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="$2"; shift 2 ;;
    --base)     BASE="$2"; shift 2 ;;
    *)          log_error "Unknown arg: $1"; exit 1 ;;
  esac
done
[[ -z "$WORKTREE" || ! -d "$WORKTREE" ]] && { log_error "--worktree <existing-path> required"; exit 1; }

cd "$WORKTREE"

CHANGED=$(git diff --name-only "origin/${BASE}...HEAD" 2>/dev/null || true)

# Schema-affecting files: any .swift under Packages/HelixPersistence/ that the
# diff touches AND that contains a SwiftData decoration we care about.
SCHEMA_FILES=()
SCHEMA_DECORATIONS_TOUCHED="false"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    Packages/HelixPersistence/*.swift|Packages/HelixPersistence/**/*.swift)
      # Only count the file if the diff hunk actually touches a relevant decoration.
      if git diff "origin/${BASE}...HEAD" -- "$f" 2>/dev/null \
        | grep -E '^[+-][[:space:]]*(@Attribute|@Relationship|@Model|@Transient|var\s+[A-Za-z_][A-Za-z0-9_]*\s*:)' \
        | grep -v '^[+-][[:space:]]*//' \
        | head -1 | grep -q .; then
        SCHEMA_FILES+=("$f")
        SCHEMA_DECORATIONS_TOUCHED="true"
      fi
      ;;
  esac
done <<< "$CHANGED"

REASONS=()
OK="true"

if [[ "$SCHEMA_DECORATIONS_TOUCHED" == "true" ]]; then
  # Migration plan must be updated. We look at HelixModelSchema.swift for a
  # SchemaMigrationPlan / VersionedSchema bump in the same diff.
  SCHEMA_DEF=$(echo "$CHANGED" | grep -E 'HelixModelSchema\.swift$' | head -1 || true)
  if [[ -z "$SCHEMA_DEF" ]]; then
    OK="false"
    REASONS+=("@Model decoration changed in $(printf '%s ' "${SCHEMA_FILES[@]}") but HelixModelSchema.swift was NOT updated — SwiftData migration plan must increment versionedSchema and add a stage")
  else
    # Verify the diff to HelixModelSchema actually adds a VersionedSchema or
    # MigrationStage reference, not just whitespace edits.
    if ! git diff "origin/${BASE}...HEAD" -- "$SCHEMA_DEF" 2>/dev/null \
       | grep -E '^\+.*(VersionedSchema|MigrationStage|SchemaMigrationPlan)' \
       | head -1 | grep -q .; then
      OK="false"
      REASONS+=("HelixModelSchema.swift was edited but no VersionedSchema or MigrationStage was added — schema-affecting diffs must come with a real migration plan")
    fi
  fi
fi

REASONS_JSON=$(printf '%s\n' "${REASONS[@]+"${REASONS[@]}"}" | jq -R . | jq -s '.')
SCHEMA_FILES_JSON=$(printf '%s\n' "${SCHEMA_FILES[@]+"${SCHEMA_FILES[@]}"}" | jq -R . | jq -s '.')

jq -n \
  --arg wt "$WORKTREE" \
  --argjson files "$SCHEMA_FILES_JSON" \
  --argjson reasons "$REASONS_JSON" \
  --argjson ok "$OK" \
  '{worktree:$wt, schema_files_changed:$files, ok:$ok, reasons:$reasons}'

[[ "$OK" == "true" ]] && exit 0 || exit 1
