#!/bin/bash
# protect-plugin-json.sh — PreToolUse hook (Edit/Write/MultiEdit) that
# refuses any edit to plugin.json which removes the agents/commands/hooks
# arrays. The lesson from feedback_dont_remove_working_registration.md is
# that those arrays are load-bearing for the current Claude Code loader,
# even though a memory rule says they're redundant. Set
# ALLOW_PLUGIN_JSON_MIN=1 to bypass after explicit verification against
# /plugin or equivalent.
#
# Hooks pass tool args via stdin as JSON. We read it, inspect file_path
# and the proposed contents/diff, and exit 2 with a stderr message to
# block the call when the guard fires.

set -euo pipefail

# Bypass switch (user explicitly verified registration via /plugin first).
if [[ "${ALLOW_PLUGIN_JSON_MIN:-0}" == "1" ]]; then
  exit 0
fi

INPUT=$(cat)

# Hooks receive JSON like {"tool_name":"Edit","tool_input":{"file_path":"...","old_string":"...","new_string":"..."}}
# We use jq to robustly pull the relevant fields. If jq isn't installed for
# any reason, fall through (don't block).
command -v jq >/dev/null 2>&1 || exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
[[ -z "$FILE_PATH" ]] && exit 0

# Only police plugin.json files (top-level or .claude-plugin/).
case "$FILE_PATH" in
  */plugin.json|*/.claude-plugin/plugin.json) ;;
  *) exit 0 ;;
esac

# Pull the proposed full content (Write) or new_string (Edit/MultiEdit).
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
PROPOSED=""
case "$TOOL" in
  Write)
    PROPOSED=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || echo "")
    ;;
  Edit)
    OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null || echo "")
    NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null || echo "")
    # Look only at the diff: did old contain agents/commands/hooks arrays
    # that new no longer contains?
    for key in '"agents"' '"commands"' '"hooks"'; do
      if echo "$OLD" | grep -qF "$key" && ! echo "$NEW" | grep -qF "$key"; then
        cat <<EOF >&2
BLOCKED: edit to $FILE_PATH removes the $key registration array.

Per feedback_dont_remove_working_registration.md, removing agents/commands/hooks
arrays from plugin.json without first verifying auto-discovery against the live
Claude Code loader has historically broken plugin loading silently.

If you've actually verified discovery still works (run /plugin and confirm all
8 agents and 4 commands appear), set ALLOW_PLUGIN_JSON_MIN=1 in your env and
retry the edit. Otherwise, leave the registration in place.
EOF
        exit 2
      fi
    done
    exit 0
    ;;
  MultiEdit)
    # MultiEdit applies a sequence of edits. Walk each.
    edit_count=$(echo "$INPUT" | jq '.tool_input.edits | length' 2>/dev/null || echo 0)
    for i in $(seq 0 $((edit_count - 1))); do
      OLD=$(echo "$INPUT" | jq -r ".tool_input.edits[$i].old_string // empty")
      NEW=$(echo "$INPUT" | jq -r ".tool_input.edits[$i].new_string // empty")
      for key in '"agents"' '"commands"' '"hooks"'; do
        if echo "$OLD" | grep -qF "$key" && ! echo "$NEW" | grep -qF "$key"; then
          echo "BLOCKED: MultiEdit edit #$((i+1)) removes $key from $FILE_PATH. See feedback_dont_remove_working_registration.md. Set ALLOW_PLUGIN_JSON_MIN=1 to bypass after manual /plugin verification." >&2
          exit 2
        fi
      done
    done
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

# Write path: ensure proposed content still has the three keys (assuming
# the old file had them — we don't know for sure here without reading the
# previous version, so we just require all three be present in the proposed
# content as a defensive measure).
for key in '"agents"' '"commands"' '"hooks"'; do
  if ! echo "$PROPOSED" | grep -qF "$key"; then
    echo "BLOCKED: Write to $FILE_PATH would produce a plugin.json missing $key. See feedback_dont_remove_working_registration.md. Set ALLOW_PLUGIN_JSON_MIN=1 to bypass." >&2
    exit 2
  fi
done

exit 0
