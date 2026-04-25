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
for desc_file in "$PLUGIN_DIR/plugin.json" "$PLUGIN_DIR/.claude-plugin/plugin.json" "$PLUGIN_DIR/skills/delivery-loop/SKILL.md" "$PLUGIN_DIR/commands/delivery-loop.md"; do
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

# 9. Two-approval contract assertions
# These are the asserts that catch contract drift between docs/agents/scripts.
# A failure here means the loop will silently break the user-facing promise of
# "two emails, two approvals, everything else autonomous."
echo ""
echo "## Two-Approval Contract"

CMD="$PLUGIN_DIR/commands/delivery-loop.md"
DRAIN="$PLUGIN_DIR/scripts/drain-emails.sh"
if [[ -x "$DRAIN" ]] && grep -q 'design-emails\.sh\|drain-emails' "$CMD"; then
  ok "Orchestrator delegates email-drain to drain-emails.sh (single source of truth)"
else
  issue "commands/delivery-loop.md must invoke drain-emails.sh; the script owns queue scan, retry counter, sentinels, dead-letter escalation"
fi
if [[ -x "$DRAIN" ]] \
   && grep -q 'dead-letter design epic' "$DRAIN" \
   && grep -q 'design-' "$DRAIN" \
   && grep -q 'epic-' "$DRAIN" \
   && grep -q 'dead-letter-' "$DRAIN"; then
  ok "drain-emails.sh handles all three email globs (design/epic/dead-letter)"
else
  issue "drain-emails.sh must scan design-*.json, epic-*.json, and dead-letter-*.json"
fi

DISPATCH="$PLUGIN_DIR/scripts/dispatcher.sh"
if grep -q 'epic-final-approved' "$DISPATCH"; then
  ok "Dispatcher Rule 2 accepts epic-final-approved"
else
  issue "Dispatcher must accept both 'user-approved' and 'epic-final-approved' on Rule 2 (TestFlight gate)"
fi

POSTAGENT="$PLUGIN_DIR/scripts/postagent.sh"
if grep -q 'cleanup-epic-mockups.sh' "$POSTAGENT"; then
  ok "postagent.sh invokes cleanup-epic-mockups.sh"
else
  issue "postagent.sh must call cleanup-epic-mockups.sh after Releaser merges the last sub-card of an epic"
fi

if grep -qE 'queue_dead_letter_email\(\)' "$POSTAGENT"; then
  ok "postagent.sh queues dead-letter notification email"
else
  issue "postagent.sh must queue a dead-letter email when an agent fails 3+ times — silent stalls violate the contract"
fi

DESIGNER_REF="$PLUGIN_DIR/references/agent-designer.md"
if grep -q 'BEFORE invoking' "$DESIGNER_REF" && grep -q 'Write SwiftUI' "$DESIGNER_REF"; then
  ok "Designer reference orders mockup-authoring before generate-design.sh"
else
  issue "Designer reference must explicitly order: write SwiftUI -> register -> THEN run generate-design.sh"
fi

SCOUT_REF="$PLUGIN_DIR/references/agent-scout.md"
if grep -q 'docs/product-vision.md' "$SCOUT_REF" && grep -q 'Vision Fit' "$SCOUT_REF"; then
  ok "Scout reference reads product-vision.md and requires Vision Fit"
else
  issue "Scout reference must read docs/product-vision.md (Phase 0) and require a Vision Fit section in every PRD"
fi

if grep -q 'docs/product-vision.md' "$DESIGNER_REF"; then
  ok "Designer reference reads product-vision.md"
else
  issue "Designer reference must Read docs/product-vision.md (Step 0) — vision-aligned mockups depend on it"
fi

VFIT="$PLUGIN_DIR/scripts/validate-vision-fit.sh"
if [[ -x "$VFIT" ]]; then
  ok "validate-vision-fit.sh exists and is executable"
else
  issue "validate-vision-fit.sh must exist as the mechanical Vision Fit enforcement"
fi

# 10. Quality bar enforcement
echo ""
echo "## Design Quality Bar"
if grep -q '## Quality bar' "$DESIGNER_REF" && grep -q 'Self-critique' "$DESIGNER_REF"; then
  ok "Designer reference defines Quality Bar + Self-critique loop"
else
  issue "Designer reference must define a Quality Bar and a mandatory self-critique pass before posting panels"
fi

# 11. Vision QA gates the approval emails end-to-end
echo ""
echo "## Vision QA Gate"
GENDESIGN="$PLUGIN_DIR/scripts/generate-design.sh"
NOTIFY_TF="$PLUGIN_DIR/scripts/notify-epic-testflight.sh"
if grep -q 'vision_qa_passed:false' "$GENDESIGN" 2>/dev/null; then
  ok "design-*.json carries vision_qa_passed flag"
else
  issue "generate-design.sh must write vision_qa_passed:false into the design-email queue"
fi
if grep -q 'vision_qa_passed:false' "$NOTIFY_TF" 2>/dev/null; then
  ok "epic-*.json carries vision_qa_passed flag"
else
  issue "notify-epic-testflight.sh must write vision_qa_passed:false into the testflight-email queue"
fi
if grep -q 'screenshots' "$GENDESIGN" && grep -q 'screenshots' "$NOTIFY_TF"; then
  ok "Both queue writers include the screenshots array (orchestrator Reads them with vision)"
else
  issue "Queue writers must include the screenshots[] array so the orchestrator can run vision QA before sending"
fi
if grep -q 'mark-vision-pass' "$DRAIN" && grep -q 'mark-vision-fail' "$DRAIN"; then
  ok "drain-emails.sh has Stage A vision-QA gate (mark-vision-pass + mark-vision-fail)"
else
  issue "drain-emails.sh must implement BOTH mark-vision-pass and mark-vision-fail handlers"
fi
if grep -qE 'MAX_VISION_RETRIES|vision_qa_retries' "$DRAIN"; then
  ok "drain-emails.sh increments vision_qa_retries and dead-letters at the cap"
else
  issue "drain-emails.sh must increment vision_qa_retries and dead-letter at >=3 attempts"
fi
VQA_PROMPT="$PLUGIN_DIR/references/vision-qa-prompt.md"
if [[ -f "$VQA_PROMPT" ]]; then
  ok "Vision-QA subagent prompt is in references/vision-qa-prompt.md (single source)"
else
  issue "references/vision-qa-prompt.md must exist; orchestrator hands it to subagent at Stage A"
fi
if grep -q 'GMAIL_DOWN_SENTINEL' "$DRAIN" && grep -q 'helix-gmail-mcp-down' "$DRAIN"; then
  ok "drain-emails.sh owns the gmail-mcp-down sentinel (kept for legacy MCP-failure paths even though the loop now fires PushNotification only)"
else
  issue "drain-emails.sh must own the /tmp/helix-gmail-mcp-down sentinel"
fi
# The new contract: no Gmail send, just PushNotification + GitHub auto-email.
# Catch any reintroduction of mcp__claude_ai_Gmail__send_message (which doesn't exist).
if grep -RIn 'mcp__claude_ai_Gmail__send_message' "$PLUGIN_DIR" 2>/dev/null | grep -v audit.sh | head -1 | grep -q .; then
  issue "References to mcp__claude_ai_Gmail__send_message exist but that MCP tool doesn't exist. Use PushNotification + GitHub-auto-email instead. (See delivery-loop.md Step 1.)"
else
  ok "No references to the non-existent mcp__claude_ai_Gmail__send_message tool"
fi
# The new path uses PushNotification.
if grep -q 'PushNotification' "$CMD"; then
  ok "delivery-loop.md uses PushNotification for the instant approval alert"
else
  issue "delivery-loop.md must call PushNotification when the queue's send action fires (the actual content arrives via GitHub's auto-email)"
fi

# 12. Mockup-reuse pipeline (Builder must consume Designer's mockups)
echo ""
echo "## Mockup Reuse"
BUILDER_REF="$PLUGIN_DIR/references/agent-builder.md"
if grep -q 'PreviewHost/Mockups' "$BUILDER_REF" && grep -qE "(Copy the mockup|mockup view's structure|use these as your starting|structural starting|starting point)" "$BUILDER_REF"; then
  ok "Builder reference instructs starting from Designer's SwiftUI mockup files"
else
  issue "agent-builder.md must instruct Builder to copy the Designer's SwiftUI mockup view structure as the shipping view's starting point"
fi
if grep -q 'epic_mockup_dir\|PreviewHost/Mockups' "$PLUGIN_DIR/scripts/run-agent.sh"; then
  ok "run-agent.sh injects mockup file paths into Builder prompt"
else
  issue "run-agent.sh must surface PreviewHost/Mockups/<epic>/*.swift paths in the Builder prompt so the agent can't miss them"
fi

# 13. Premature epic-approved guard
echo ""
echo "## Premature-Approval Guard"
if grep -q 'Premature-approval guard\|HasUIChanges.*Yes.*DesignURL' "$DISPATCH"; then
  ok "Dispatcher Rule 7b guards against epic-approved before mockups are posted"
else
  issue "Dispatcher Rule 7b must reject epic-approved when HasUIChanges=Yes and DesignURL is empty (route to Designer first)"
fi

# 14. Regen-without-change guard
echo ""
echo "## Regen Change Guard"
if grep -q 'verify_regen_changed\|byte-identical' "$PLUGIN_DIR/scripts/generate-design.sh"; then
  ok "generate-design.sh refuses --regenerate when SwiftUI files are byte-identical"
else
  issue "generate-design.sh must refuse --regenerate when SwiftUI mockup files haven't actually changed"
fi

# 15. TestFlight failure routing
echo ""
echo "## TestFlight Failure Path"
if grep -q 'TF_OK.*false\|testflight-upload-failed\|did not send approval email' "$PLUGIN_DIR/scripts/notify-epic-testflight.sh"; then
  ok "notify-epic-testflight.sh refuses to queue approval email when TestFlight upload fails"
else
  issue "notify-epic-testflight.sh must NOT queue an approval email when TestFlight upload fails — queue dead-letter instead"
fi

# 16. Rebase-conflict routing
echo ""
echo "## Rebase Conflict Routing"
if grep -q 'rebase-conflict.*--add-label\|--add-label.*rework' "$PLUGIN_DIR/scripts/rebase-open-prs.sh"; then
  ok "rebase-open-prs.sh labels conflicting PRs with rebase-conflict + rework so dispatcher Rule 3 routes Builder"
else
  issue "rebase-open-prs.sh must add 'rebase-conflict' and 'rework' labels on conflict so dispatcher Rule 3 picks it up"
fi

# 17. Sub-card ownership: Planner creates sub-cards, Scout hands off
echo ""
echo "## Sub-Card Ownership"
if grep -q 'Scout does \*\*not\*\* create sub-cards\|Scout does not create sub-cards' "$SCOUT_REF"; then
  ok "Scout reference defers sub-card creation to Planner (no ambiguity)"
else
  issue "Scout reference must explicitly state Scout does not create sub-cards (Planner does, per Rule 7b → Planner)"
fi
if grep -q 'Break the epic into \*\*sub-cards\*\*' "$PLUGIN_DIR/references/agent-planner.md"; then
  ok "Planner reference owns sub-card creation"
else
  issue "Planner reference must own sub-card creation (Epic Rule)"
fi
if grep -q 'EC-7' "$POSTAGENT"; then
  ok "postagent EC-7 enforces 'epic with 0 sub-cards is a Planner failure'"
else
  issue "postagent.sh must include EC-7: detect epic with 0 sub-cards after Planner runs and force re-route"
fi

# 18. Concurrency lock around autodev write
echo ""
echo "## Autodev Write Lock"
if grep -qE 'acquire_autodev_lock\b' "$PLUGIN_DIR/scripts/cleanup-epic-mockups.sh" \
   && grep -qE 'AUTODEV_LOCK=' "$PLUGIN_DIR/scripts/cleanup-epic-mockups.sh"; then
  ok "cleanup-epic-mockups.sh holds an autodev write lock during commit/push"
else
  issue "cleanup-epic-mockups.sh must hold an mkdir-based lock on autodev writes to prevent concurrent-merge races"
fi

# 19. Reviewer uses a different AI (Codex / OpenAI) than Builder
echo ""
echo "## Reviewer Independence"
REVIEWER_REF="$PLUGIN_DIR/references/agent-reviewer.md"
if grep -qE 'OpenAI Codex|codex --|codex CLI' "$REVIEWER_REF"; then
  ok "Reviewer reference invokes OpenAI Codex (different model than Opus that built the code)"
else
  issue "Reviewer reference must invoke OpenAI Codex CLI so the reviewer is a different AI from the Builder — same-model self-review is biased"
fi
# Builder rework gets the best model, not a cheaper fallback (per
# feedback_rework_uses_best_model.md: first attempt failed → second is harder)
if grep -qE '^MODEL_BUILDER_REWORK="opus"' "$PLUGIN_DIR/scripts/config.sh"; then
  ok "Builder rework uses Opus (best model when fixing mistakes)"
else
  issue "MODEL_BUILDER_REWORK must be 'opus' — retries need the strongest model, not a cheaper fallback"
fi

# Summary
echo ""
echo "=== Audit Complete ==="
echo "Errors:   $ISSUES"
echo "Warnings: $WARNINGS"

[[ "$ISSUES" -gt 0 ]] && exit 1
exit 0
