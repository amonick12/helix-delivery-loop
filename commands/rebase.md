---
name: rebase
description: "Rebase all open PRs on autodev after a merge"
---

# Rebase Open PRs

Rebase all open feature branches on the latest autodev to fix conflicts.

## Steps

1. **Pull latest autodev:**
   ```bash
   git pull --ff-only origin autodev 2>&1
   ```

2. **Rebase all open PRs:**
   ```bash
   SCRIPTS="/Users/aaronmonick/.claude/plugins/cache/local/helix-delivery-loop/3.0.0/scripts"
   bash "$SCRIPTS/rebase-open-prs.sh" 2>&1
   ```

3. **Report results** — for each PR, show whether rebase succeeded or has conflicts.
