#!/bin/bash
# audit.sh — Self-consistency audit for the delivery loop plugin.
# Checks that all references, scripts, and agent definitions are consistent.
#
# Usage:
#   ./audit.sh              # Run full audit
#   ./audit.sh --fix        # Auto-fix what's possible
#
# Returns: exit 0 if clean, exit 1 if issues found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FIX=false
[[ "${1:-}" == "--fix" ]] && FIX=true

ISSUES=0
WARNINGS=0

issue() { echo "  ERROR: $1"; ISSUES=$((ISSUES + 1)); }
warn()  { echo "  WARN:  $1"; WARNINGS=$((WARNINGS + 1)); }
ok()    { echo "  OK:    $1"; }

echo "=== Delivery Loop Plugin Audit ==="
echo ""

# 1. Check all agent files referenced in plugin.json exist
echo "## Agent Definitions"
AGENTS=$(jq -r '.agents[]' "$PLUGIN_DIR/plugin.json" 2>/dev/null)
for agent_file in $AGENTS; do
  if [[ -f "$PLUGIN_DIR/$agent_file" ]]; then
    ok "$agent_file exists"
  else
    issue "$agent_file referenced in plugin.json but missing"
  fi
done

# 2. Check for stale terminology (Verifier, Stabilizer, Merger)
echo ""
echo "## Terminology Consistency"
for term in "Verifier" "Stabilizer" "Merger"; do
  # Exclude audit.sh itself (it contains the search terms as literals)
  MATCHES=$(grep -rl "$term" "$PLUGIN_DIR" --include="*.md" --include="*.json" --include="*.sh" 2>/dev/null | grep -v "audit.sh" || true)
  COUNT=0
  [[ -n "$MATCHES" ]] && COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
  if [[ "$COUNT" -gt 0 ]]; then
    issue "Found $COUNT files still referencing '$term':"
    echo "$MATCHES" | sed 's/^/    /'
  else
    ok "No references to '$term'"
  fi
done

# 3. Check agent count consistency
echo ""
echo "## Agent Count"
AGENT_FILE_COUNT=$(ls "$PLUGIN_DIR/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
PLUGIN_JSON_COUNT=$(jq '.agents | length' "$PLUGIN_DIR/plugin.json" 2>/dev/null)
if [[ "$AGENT_FILE_COUNT" -eq "$PLUGIN_JSON_COUNT" ]]; then
  ok "Agent files ($AGENT_FILE_COUNT) matches plugin.json ($PLUGIN_JSON_COUNT)"
else
  issue "Agent files ($AGENT_FILE_COUNT) != plugin.json ($PLUGIN_JSON_COUNT)"
fi

# Check descriptions say correct count
for desc_file in "$PLUGIN_DIR/.claude-plugin/plugin.json" "$PLUGIN_DIR/skills/delivery-loop/SKILL.md" "$PLUGIN_DIR/commands/delivery-loop.md"; do
  if [[ -f "$desc_file" ]]; then
    if grep -qi "eight\|8 agents" "$desc_file" 2>/dev/null; then
      ok "$(basename "$desc_file") says 8 agents"
    elif grep -qi "seven\|7 agents\|six\|6 agents" "$desc_file" 2>/dev/null; then
      issue "$(basename "$desc_file") has stale agent count"
    fi
  fi
done

# 4. Check all scripts are executable
echo ""
echo "## Script Permissions"
NON_EXEC=0
for script in "$PLUGIN_DIR/scripts/"*.sh "$PLUGIN_DIR/hooks/scripts/"*.sh; do
  [[ ! -f "$script" ]] && continue
  if [[ ! -x "$script" ]]; then
    if [[ "$FIX" == "true" ]]; then
      chmod +x "$script"
      warn "Fixed: $(basename "$script") made executable"
    else
      issue "$(basename "$script") is not executable"
    fi
    NON_EXEC=$((NON_EXEC + 1))
  fi
done
[[ "$NON_EXEC" -eq 0 ]] && ok "All scripts are executable"

# 5. Check plugin.json versions match
echo ""
echo "## Version Consistency"
V1=$(jq -r '.version' "$PLUGIN_DIR/plugin.json" 2>/dev/null)
V2=$(jq -r '.version' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null)
if [[ "$V1" == "$V2" ]]; then
  ok "Versions match: $V1"
else
  issue "plugin.json ($V1) != .claude-plugin/plugin.json ($V2)"
fi

# 6. Check reference docs exist for each agent
echo ""
echo "## Reference Docs"
for agent_name in scout maintainer designer planner builder reviewer tester releaser; do
  REF="$PLUGIN_DIR/references/agent-${agent_name}.md"
  if [[ -f "$REF" ]]; then
    ok "agent-${agent_name}.md exists"
  else
    issue "Missing reference doc: agent-${agent_name}.md"
  fi
done

# 7. Check for orphaned state entries
echo ""
echo "## State Health"
STATE_FILE="${PLUGIN_DIR}/../../delivery-loop-state.json"
if [[ -f "$STATE_FILE" ]]; then
  IN_FLIGHT=$(jq '.in_flight // [] | length' "$STATE_FILE" 2>/dev/null || echo 0)
  CARD_COUNT=$(jq '.cards | length' "$STATE_FILE" 2>/dev/null || echo 0)
  if [[ "$IN_FLIGHT" -gt 0 ]]; then
    warn "$IN_FLIGHT in-flight entries (may be stale if no agents running)"
  fi
  ok "$CARD_COUNT cards tracked in state"
else
  ok "No state file (clean slate)"
fi

# 8. Check dispatcher rules reference valid agents
echo ""
echo "## Dispatcher Validation"
DISPATCHER="$PLUGIN_DIR/scripts/dispatcher.sh"
if [[ -f "$DISPATCHER" ]]; then
  for agent in scout designer planner builder reviewer tester releaser; do
    if grep -q "\"$agent\"" "$DISPATCHER"; then
      ok "Dispatcher references $agent"
    else
      warn "Dispatcher doesn't reference $agent"
    fi
  done
  if grep -q '"verifier"' "$DISPATCHER"; then
    issue "Dispatcher still references 'verifier'"
  fi
fi

# Summary
echo ""
echo "=== Audit Complete ==="
echo "Errors:   $ISSUES"
echo "Warnings: $WARNINGS"

[[ "$ISSUES" -gt 0 ]] && exit 1
exit 0
