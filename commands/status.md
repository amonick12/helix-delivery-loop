---
name: status
description: "Show delivery loop pipeline status — board, PRs, agents, stuck cards, next dispatch"
---

# Delivery Loop Status

Run the status script and present the results to the user.

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$SCRIPTS/status.sh" 2>/dev/null
```

Present the output directly. If the script fails, fall back to running these individually:

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
# Board state
bash "$SCRIPTS/read-board.sh" 2>/dev/null | jq -r '.cards[] | "#\(.issue_number) \(.title[:50]) [\(.fields.Status)]"'
# Next dispatch
bash "$SCRIPTS/dispatcher.sh" --dry-run 2>/dev/null
```
