#!/bin/bash
# PreToolUse hook: block writing screenshot/recording files into the repo
# Screenshots must go to GitHub Releases via gh release upload, never committed

REPO_ROOT="/Users/aaronmonick/Downloads/helix"

file_path=$(echo "$CLAUDE_TOOL_INPUT" | jq -r '.file_path // ""' 2>/dev/null)

if [[ $? -ne 0 ]]; then
  echo "[helix] ERROR: Could not parse CLAUDE_TOOL_INPUT — blocking as precaution" >&2
  exit 2
fi

if [[ -z "$file_path" ]]; then
  exit 0
fi

# Only block writes inside the repo (not /tmp/ or other paths)
if [[ "$file_path" != "$REPO_ROOT"* ]]; then
  exit 0
fi

# Block image and video files
case "${file_path##*.}" in
  png|jpg|jpeg|gif|mov|mp4|webp|heic|heif)
    echo "[helix] BLOCKED: Cannot write $file_path into the repo. Screenshots/recordings must be uploaded via: gh release upload screenshots <file> --repo amonick12/helix" >&2
    exit 2
    ;;
esac

exit 0
