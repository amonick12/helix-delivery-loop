#!/bin/bash
# register-uitest.sh — Register a new XCUITest file in the Xcode project.
#
# Usage:
#   ./register-uitest.sh --file helix-appUITests/NewTest.swift --worktree /tmp/helix-wt/feature/137-slug
#
# Checks if the UITests group uses PBXFileSystemSynchronizedRootGroup (auto-sync).
# If synced, registration is not needed and the script exits cleanly.
# If not synced, adds the file to the pbxproj.
#
# Env:
#   DRY_RUN=1   Skip file modifications, print what would happen

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
register-uitest.sh — Register a new XCUITest file in the Xcode project.

Usage:
  ./register-uitest.sh --file helix-appUITests/NewTest.swift --worktree /tmp/helix-wt/feature/137-slug

Options:
  --file <path>       Relative path to the Swift test file (required)
  --worktree <path>   Worktree path containing the Xcode project (required)

If the UITests target uses PBXFileSystemSynchronizedRootGroup, no registration
is needed and the script exits with a success message.

Env:
  DRY_RUN=1   Skip file modifications, print what would happen
HELP

# ── Parse args ─────────────────────────────────────────
FILE_PATH=""
WORKTREE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)     FILE_PATH="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    *)          log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$FILE_PATH" ]]; then
  log_error "--file <path> is required"
  exit 1
fi
if [[ -z "$WORKTREE" ]]; then
  log_error "--worktree <path> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# ── Locate pbxproj ────────────────────────────────────
PBXPROJ="$WORKTREE/helix-app.xcodeproj/project.pbxproj"

if [[ ! -f "$PBXPROJ" ]]; then
  log_error "pbxproj not found at $PBXPROJ"
  exit 1
fi

# ── Check if UITests uses PBXFileSystemSynchronizedRootGroup ──
# If the project uses file system sync for the UITests directory,
# new files are auto-compiled and no manual registration is needed.
# Look specifically for helix-appUITests in the synced root groups section
# The section format is: path = "helix-appUITests"; under isa = PBXFileSystemSynchronizedRootGroup
SYNCED_SECTION=$(sed -n '/Begin PBXFileSystemSynchronizedRootGroup/,/End PBXFileSystemSynchronizedRootGroup/p' "$PBXPROJ" 2>/dev/null || echo "")
if echo "$SYNCED_SECTION" | grep -q 'helix-appUITests'; then
  log_info "UITests uses PBXFileSystemSynchronizedRootGroup — no registration needed"
  echo '{"registered": false, "reason": "auto-synced", "file": "'"$FILE_PATH"'"}'
  exit 0
fi

# ── Check if the file is already referenced ───────────
FILE_NAME=$(basename "$FILE_PATH")
if grep -q "$FILE_NAME" "$PBXPROJ"; then
  log_info "$FILE_NAME is already referenced in the project"
  echo '{"registered": false, "reason": "already_registered", "file": "'"$FILE_PATH"'"}'
  exit 0
fi

# ── Generate unique UUIDs ─────────────────────────────
# Xcode uses 24-character hex UUIDs
generate_uuid() {
  python3 -c "import uuid; print(uuid.uuid4().hex[:24].upper())"
}

FILE_REF_UUID=$(generate_uuid)
BUILD_FILE_UUID=$(generate_uuid)

if [[ "$DRY_RUN" == "1" ]]; then
  log_info "[DRY_RUN] Would register $FILE_NAME in pbxproj:"
  log_info "[DRY_RUN]   File ref UUID: $FILE_REF_UUID"
  log_info "[DRY_RUN]   Build file UUID: $BUILD_FILE_UUID"
  log_info "[DRY_RUN]   pbxproj: $PBXPROJ"
  echo '{"registered": false, "reason": "dry_run", "file": "'"$FILE_PATH"'"}'
  exit 0
fi

# ── Use python3 for reliable pbxproj editing ──────────
python3 << PYEOF
import re
import sys

pbxproj_path = "$PBXPROJ"
file_name = "$FILE_NAME"
file_path = "$FILE_PATH"
file_ref_uuid = "$FILE_REF_UUID"
build_file_uuid = "$BUILD_FILE_UUID"

with open(pbxproj_path, 'r') as f:
    content = f.read()

# 1. Add PBXFileReference
file_ref_line = f'\t\t{file_ref_uuid} /* {file_name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {file_name}; sourceTree = "<group>"; }};\n'
# Insert after the last PBXFileReference entry
file_ref_section_end = content.find('/* End PBXFileReference section */')
if file_ref_section_end == -1:
    print("ERROR: Could not find PBXFileReference section", file=sys.stderr)
    sys.exit(1)
content = content[:file_ref_section_end] + file_ref_line + content[file_ref_section_end:]

# 2. Add PBXBuildFile
build_file_line = f'\t\t{build_file_uuid} /* {file_name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_uuid} /* {file_name} */; }};\n'
build_file_section_end = content.find('/* End PBXBuildFile section */')
if build_file_section_end == -1:
    print("ERROR: Could not find PBXBuildFile section", file=sys.stderr)
    sys.exit(1)
content = content[:build_file_section_end] + build_file_line + content[build_file_section_end:]

# 3. Add to helix-appUITests PBXGroup children
# Find the UITests group and add the file reference to its children
uitests_pattern = re.compile(r'(/\* helix-appUITests \*/ = \{[^}]*children = \(\n)(.*?)(\n\s*\);)', re.DOTALL)
match = uitests_pattern.search(content)
if match:
    children_end = match.start(3)
    new_child = f'\t\t\t\t{file_ref_uuid} /* {file_name} */,\n'
    content = content[:children_end] + new_child + content[children_end:]
else:
    print("WARNING: Could not find helix-appUITests PBXGroup — file ref added but not grouped", file=sys.stderr)

# 4. Add to PBXSourcesBuildPhase for UITests target
# Find the UITests Sources build phase and add the build file
sources_pattern = re.compile(r'(/\* Sources \*/ = \{[^}]*isa = PBXSourcesBuildPhase;[^}]*files = \(\n)(.*?)(\n\s*\);)', re.DOTALL)
# We need to find the right Sources phase — the one for the UITests target
# Look for it after the UITests target definition
uitests_target_pos = content.find('helix-appUITests')
if uitests_target_pos != -1:
    # Find Sources build phase after UITests target
    for m in sources_pattern.finditer(content):
        if m.start() > uitests_target_pos:
            files_end = m.start(3)
            new_file = f'\t\t\t\t{build_file_uuid} /* {file_name} in Sources */,\n'
            content = content[:files_end] + new_file + content[files_end:]
            break

with open(pbxproj_path, 'w') as f:
    f.write(content)

print(f"Registered {file_name} in pbxproj")
PYEOF

if [[ $? -eq 0 ]]; then
  log_info "Registered $FILE_NAME in $PBXPROJ"
  echo '{"registered": true, "reason": "added_to_pbxproj", "file": "'"$FILE_PATH"'"}'
else
  log_error "Failed to register $FILE_NAME in pbxproj"
  echo '{"registered": false, "reason": "pbxproj_edit_failed", "file": "'"$FILE_PATH"'"}'
  exit 1
fi
