#!/bin/bash
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hooks/scripts/protect-plugin-json.sh"

PASS=0; FAIL=0
report_pass() { PASS=$((PASS+1)); }
report_fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_hook() {
  local input="$1"; local env="${2:-}"
  set +e
  if [[ -n "$env" ]]; then
    echo "$input" | env "$env" bash "$SCRIPT" >/dev/null 2>&1
  else
    echo "$input" | bash "$SCRIPT" >/dev/null 2>&1
  fi
  local rc=$?
  set -e
  echo "$rc"
}

# ── Edit removing agents → block (exit 2) ──────────────
RC=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/x/plugin.json","old_string":"\"agents\": [\"a\"]","new_string":"\"hooks\": \"x\""}}')
[[ "$RC" == "2" ]] && report_pass || report_fail "Edit removing agents: expected exit 2, got $RC"

# ── Edit removing commands → block ─────────────────────
RC=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/x/plugin.json","old_string":"\"commands\": []","new_string":"\"version\":\"1\""}}')
[[ "$RC" == "2" ]] && report_pass || report_fail "Edit removing commands: expected exit 2, got $RC"

# ── Edit removing hooks → block ────────────────────────
RC=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/x/plugin.json","old_string":"\"hooks\": \"hooks/hooks.json\"","new_string":"\"keywords\":[\"a\"]"}}')
[[ "$RC" == "2" ]] && report_pass || report_fail "Edit removing hooks: expected exit 2, got $RC"

# ── Edit modifying agents (still present) → allow ──────
RC=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/x/plugin.json","old_string":"\"agents\": [\"a\"]","new_string":"\"agents\": [\"a\",\"b\"]"}}')
[[ "$RC" == "0" ]] && report_pass || report_fail "Edit keeping agents: expected exit 0, got $RC"

# ── Edit on non-plugin.json → allow (skip) ─────────────
RC=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/x/other.json","old_string":"\"agents\": []","new_string":"\"x\":1"}}')
[[ "$RC" == "0" ]] && report_pass || report_fail "Non-plugin.json edit: expected exit 0, got $RC"

# ── ALLOW_PLUGIN_JSON_MIN bypass ───────────────────────
RC=$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/x/plugin.json","old_string":"\"agents\": []","new_string":"\"x\":1"}}' "ALLOW_PLUGIN_JSON_MIN=1")
[[ "$RC" == "0" ]] && report_pass || report_fail "ALLOW_PLUGIN_JSON_MIN bypass: expected exit 0, got $RC"

# ── Write missing all 3 keys → block ───────────────────
RC=$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/plugin.json","content":"{\"name\":\"foo\"}"}}')
[[ "$RC" == "2" ]] && report_pass || report_fail "Write missing keys: expected exit 2, got $RC"

# ── Write with all 3 keys → allow ──────────────────────
RC=$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/plugin.json","content":"{\"agents\":[],\"commands\":[],\"hooks\":\"x\"}"}}')
[[ "$RC" == "0" ]] && report_pass || report_fail "Write with all keys: expected exit 0, got $RC"

# ── MultiEdit removing agents in step 2 → block ────────
RC=$(run_hook '{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/plugin.json","edits":[{"old_string":"a","new_string":"b"},{"old_string":"\"agents\":[]","new_string":"\"x\":1"}]}}')
[[ "$RC" == "2" ]] && report_pass || report_fail "MultiEdit removing agents: expected exit 2, got $RC"

# ── MultiEdit keeping all keys → allow ─────────────────
RC=$(run_hook '{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/plugin.json","edits":[{"old_string":"a","new_string":"b"}]}}')
[[ "$RC" == "0" ]] && report_pass || report_fail "MultiEdit unrelated: expected exit 0, got $RC"

# ── Unknown tool → allow ───────────────────────────────
RC=$(run_hook '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}')
[[ "$RC" == "0" ]] && report_pass || report_fail "Unknown tool: expected exit 0, got $RC"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
