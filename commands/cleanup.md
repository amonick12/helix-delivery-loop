---
name: cleanup
description: "Clean up stale worktrees, branches, and artifacts for Done cards"
---

# Cleanup

Remove stale worktrees, local branches, and artifacts for cards that are Done or have closed PRs.

## Steps

1. **Clean stale worktrees:**
   ```bash
   SCRIPTS="/Users/aaronmonick/.claude/plugins/cache/local/helix-delivery-loop/3.0.0/scripts"
   bash "$SCRIPTS/worktree.sh" cleanup-stale 2>&1
   ```

2. **List remaining worktrees:**
   ```bash
   git worktree list 2>/dev/null | grep helix-wt
   ```

3. **Clean orphaned artifacts:**
   ```bash
   # Find artifact dirs for cards that are Done
   for dir in /tmp/helix-artifacts/*/; do
     CARD=$(basename "$dir")
     STATUS=$(gh issue view "$CARD" --repo amonick12/helix --json state --jq '.state' 2>/dev/null)
     if [[ "$STATUS" == "CLOSED" ]]; then
       rm -rf "$dir"
       echo "Removed artifacts for closed card #$CARD"
     fi
   done
   ```

4. **Clean stale state entries:**
   ```bash
   bash "$SCRIPTS/state.sh" list 2>/dev/null
   ```
   For each card in state that is Done/closed, run `bash "$SCRIPTS/state.sh" clear <card>`.

5. **Report** what was cleaned.
