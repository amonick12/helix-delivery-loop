---
name: approve
description: "Approve a PR — adds user-approved label, syncs to issue, triggers Releaser on next dispatch"
arguments:
  - name: pr
    description: "PR number to approve"
    required: true
---

# Approve PR

Add `user-approved` label to a PR and its linked issue, triggering the Releaser on the next `/delivery-loop` dispatch.

## Steps

1. **Parse PR number:**
   ```bash
   PR_NUMBER="$ARGUMENTS"
   ```

2. **Add label to PR:**
   ```bash
   gh pr edit "$PR_NUMBER" --repo amonick12/helix --add-label "user-approved" 2>/dev/null
   ```

3. **Find linked issue and add label there too:**
   ```bash
   BODY=$(gh pr view "$PR_NUMBER" --repo amonick12/helix --json body --jq '.body' 2>/dev/null)
   CARD=$(echo "$BODY" | grep -oE 'Closes #[0-9]+' | grep -oE '[0-9]+' | head -1)
   if [[ -z "$CARD" ]]; then
     BRANCH=$(gh pr view "$PR_NUMBER" --repo amonick12/helix --json headRefName --jq '.headRefName' 2>/dev/null)
     CARD=$(echo "$BRANCH" | grep -oE '[0-9]+' | head -1)
   fi
   if [[ -n "$CARD" ]]; then
     gh issue edit "$CARD" --repo amonick12/helix --add-label "user-approved" 2>/dev/null
     echo "Added user-approved to PR #$PR_NUMBER and issue #$CARD"
   else
     echo "Added user-approved to PR #$PR_NUMBER (no linked issue found)"
   fi
   ```

4. **Sync all labels** to catch any other mismatches:
   ```bash
   SCRIPTS="/Users/aaronmonick/.claude/plugins/cache/local/helix-delivery-loop/3.0.0/scripts"
   ```
   Run the sync-labels logic for this PR.

5. **Report** that the PR is approved and the Releaser will pick it up on the next `/delivery-loop`.
