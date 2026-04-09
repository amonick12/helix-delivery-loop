---
name: reject
description: "Reject a PR — posts feedback comment, removes approval labels, routes back to Builder"
arguments:
  - name: args
    description: "PR number followed by reason, e.g.: 193 the speech rate slider doesn't work"
    required: true
---

# Reject PR

Post a rejection comment on a PR, remove approval labels, and route the card back to Builder for rework.

## Steps

1. **Parse arguments:**
   ```bash
   ARGS="$ARGUMENTS"
   PR_NUMBER=$(echo "$ARGS" | awk '{print $1}')
   REASON=$(echo "$ARGS" | cut -d' ' -f2-)
   ```

2. **Post rejection comment:**
   ```bash
   gh pr comment "$PR_NUMBER" --repo amonick12/helix --body "## Rejected

   $REASON

   Routing back to Builder for rework."
   ```

3. **Remove approval labels from PR:**
   ```bash
   for label in "user-approved" "ai-approved" "visual-qa-approved" "code-review-approved" "tests-passed"; do
     gh pr edit "$PR_NUMBER" --repo amonick12/helix --remove-label "$label" 2>/dev/null
   done
   ```

4. **Find linked card:**
   ```bash
   BODY=$(gh pr view "$PR_NUMBER" --repo amonick12/helix --json body --jq '.body' 2>/dev/null)
   CARD=$(echo "$BODY" | grep -oE 'Closes #[0-9]+' | grep -oE '[0-9]+' | head -1)
   if [[ -z "$CARD" ]]; then
     BRANCH=$(gh pr view "$PR_NUMBER" --repo amonick12/helix --json headRefName --jq '.headRefName' 2>/dev/null)
     CARD=$(echo "$BRANCH" | grep -oE '[0-9]+' | head -1)
   fi
   ```

5. **Remove approval labels from issue and set rework:**
   ```bash
   if [[ -n "$CARD" ]]; then
     for label in "user-approved" "ai-approved"; do
       gh issue edit "$CARD" --repo amonick12/helix --remove-label "$label" 2>/dev/null
     done
     SCRIPTS="/Users/aaronmonick/.claude/plugins/cache/local/helix-delivery-loop/3.0.0/scripts"
     bash "$SCRIPTS/move-card.sh" --issue "$CARD" --to "In progress" 2>/dev/null
     bash "$SCRIPTS/state.sh" set "$CARD" rework_target builder 2>/dev/null
     echo "Card #$CARD moved to In Progress with rework_target=builder"
   fi
   ```

6. **Report** that the PR is rejected and Builder will pick it up on next dispatch.
