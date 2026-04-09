---
name: unstick
description: "Diagnose and fix a stuck card — clears stale state, labels, worktrees"
arguments:
  - name: card
    description: "Card/issue number"
    required: true
---

# Unstick a Card

Diagnose why a card is stuck and fix common issues.

## Steps

1. **Read current state:**
   ```bash
   CARD="$ARGUMENTS"
   SCRIPTS="/Users/aaronmonick/.claude/plugins/cache/local/helix-delivery-loop/3.0.0/scripts"
   
   echo "=== Card #$CARD State ==="
   bash "$SCRIPTS/state.sh" get "$CARD" 2>/dev/null || echo "No state file entry"
   
   echo ""
   echo "=== Board Status ==="
   bash "$SCRIPTS/read-board.sh" --card-id "$CARD" --no-cache 2>/dev/null | python3 -c "
   import sys, json
   data = json.load(sys.stdin)
   cards = data.get('cards',[])
   if cards:
     c = cards[0]
     print(f'Status: {c[\"fields\"].get(\"Status\",\"?\")}')
     print(f'Labels: {c[\"labels\"]}')
     print(f'Fields: {json.dumps(c[\"fields\"], indent=2)}')
   else:
     print('Card not on board')
   "
   
   echo ""
   echo "=== Open PR ==="
   gh pr list --repo amonick12/helix --state open --search "$CARD" --json number,title,mergeable,labels --jq '.[] | {number, mergeable, labels: [.labels[].name]}' 2>/dev/null || echo "No open PR"
   
   echo ""
   echo "=== Dispatcher View ==="
   bash "$SCRIPTS/dispatcher.sh" --dry-run 2>/dev/null | python3 -c "
   import sys, json
   d = json.load(sys.stdin)
   print(json.dumps(d, indent=2))
   " 2>/dev/null
   ```

2. **Report findings and offer fixes.** Check for these common issues:

   **Stale `rework_target`:** If state has `rework_target` set but the card's last agent completed successfully:
   ```bash
   python3 -c "
   import json
   with open('/Users/aaronmonick/Downloads/helix/.claude/delivery-loop-state.json') as f:
       data = json.load(f)
   card = data.get('cards',{}).get('$CARD',{})
   def remove_field(d, field):
       if isinstance(d, dict):
           d.pop(field, None)
           for v in d.values(): remove_field(v, field)
   remove_field(card, 'rework_target')
   with open('/Users/aaronmonick/Downloads/helix/.claude/delivery-loop-state.json', 'w') as f:
       json.dump(data, f, indent=2)
   print('Cleared stale rework_target')
   "
   ```

   **Missing gates.json:** If card is In Progress with `handoff_from: builder` but no gates file:
   ```bash
   if [[ ! -f "/tmp/helix-artifacts/$CARD/gates.json" ]]; then
     echo "Missing gates.json — run /gates $CARD"
   fi
   ```

   **Label mismatch:** If PR has `user-approved` but issue doesn't:
   ```bash
   echo "Run /sync-labels to fix"
   ```

   **Missing worktree:** If card is In Progress but worktree doesn't exist:
   ```bash
   BRANCH=$(gh pr view "$PR" --repo amonick12/helix --json headRefName --jq '.headRefName' 2>/dev/null)
   WORKTREE="/tmp/helix-wt/$BRANCH"
   if [[ ! -d "$WORKTREE" ]]; then
     echo "Worktree missing at $WORKTREE — recreating"
     git fetch origin "$BRANCH" 2>/dev/null
     git worktree add "$WORKTREE" "$BRANCH" 2>/dev/null
   fi
   ```

   **Conflicting PR:** If PR shows CONFLICTING:
   ```bash
   echo "PR has conflicts — needs rebase"
   ```

3. **After fixing, re-run dispatcher to verify:**
   ```bash
   bash "$SCRIPTS/dispatcher.sh" --dry-run 2>/dev/null
   ```
