---
name: maintainer
description: "Run the Maintainer agent — codebase health, refactors, tech debt, dependency updates"
---

# Run Maintainer

Manually dispatch the Maintainer agent for codebase health work. The Maintainer handles refactors, tech debt cleanup, dependency updates, and architectural violations — work that doesn't come from the board but keeps the codebase healthy.

## Steps

1. **Prepare the agent:**
   ```bash
   SCRIPTS="/Users/aaronmonick/.claude/plugins/cache/local/helix-delivery-loop/3.0.0/scripts"
   PROMPT=$(bash "$SCRIPTS/run-agent.sh" prepare maintainer --card 0 2>/dev/null)
   ```

2. **Launch the Maintainer agent** using the Agent tool with:
   - `subagent_type: "helix-delivery-loop:maintainer"`
   - `model: opus`
   - The prepared prompt as the agent prompt
   - `run_in_background: true`

3. **When complete**, run postagent:
   ```bash
   bash "$SCRIPTS/postagent.sh" --agent maintainer --card 0 --exit-code $EXIT_CODE --duration $SECONDS
   bash "$SCRIPTS/run-agent.sh" finish maintainer --card 0
   ```
