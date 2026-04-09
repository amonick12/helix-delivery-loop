---
name: sync-labels
description: "Sync approval labels between PRs and their linked issues"
arguments:
  - name: target
    description: "PR number, or 'all' to sync all open PRs (default: all)"
    required: false
---

# Sync Labels

Sync approval labels (`user-approved`, `ai-approved`, `code-review-approved`, `visual-qa-approved`) between PRs and their linked issues. The dispatcher checks issue labels, but users often add labels to PRs — this command ensures they match.

## Steps

1. **Get target PRs:**
   ```bash
   TARGET="$ARGUMENTS"
   if [[ -z "$TARGET" || "$TARGET" == "all" ]]; then
     PRS=$(gh pr list --repo amonick12/helix --state open --json number --jq '.[].number' 2>/dev/null)
   else
     PRS="$TARGET"
   fi
   ```

2. **For each PR, sync labels to the linked issue:**
   ```bash
   SYNC_LABELS=("user-approved" "ai-approved" "code-review-approved" "visual-qa-approved" "awaiting-visual-qa" "awaiting-code-review")
   
   for PR in $PRS; do
     # Get PR labels
     PR_LABELS=$(gh pr view "$PR" --repo amonick12/helix --json labels --jq '[.labels[].name]' 2>/dev/null)
     
     # Find linked issue from PR body (Closes #N)
     CARD=$(gh pr view "$PR" --repo amonick12/helix --json body --jq '.body' 2>/dev/null | grep -oE 'Closes #[0-9]+' | grep -oE '[0-9]+' | head -1)
     if [[ -z "$CARD" ]]; then
       # Try branch name
       BRANCH=$(gh pr view "$PR" --repo amonick12/helix --json headRefName --jq '.headRefName' 2>/dev/null)
       CARD=$(echo "$BRANCH" | grep -oE '[0-9]+' | head -1)
     fi
     
     if [[ -z "$CARD" ]]; then
       echo "PR #$PR: no linked issue found — skipping"
       continue
     fi
     
     # Get issue labels
     ISSUE_LABELS=$(gh issue view "$CARD" --repo amonick12/helix --json labels --jq '[.labels[].name]' 2>/dev/null)
     
     CHANGED=false
     for LABEL in "${SYNC_LABELS[@]}"; do
       PR_HAS=$(echo "$PR_LABELS" | jq --arg l "$LABEL" 'any(. == $l)')
       ISSUE_HAS=$(echo "$ISSUE_LABELS" | jq --arg l "$LABEL" 'any(. == $l)')
       
       # PR has it but issue doesn't → add to issue
       if [[ "$PR_HAS" == "true" && "$ISSUE_HAS" == "false" ]]; then
         gh issue edit "$CARD" --repo amonick12/helix --add-label "$LABEL" 2>/dev/null
         echo "  PR #$PR → Issue #$CARD: added '$LABEL'"
         CHANGED=true
       fi
       
       # Issue has it but PR doesn't → add to PR
       if [[ "$ISSUE_HAS" == "true" && "$PR_HAS" == "false" ]]; then
         gh pr edit "$PR" --repo amonick12/helix --add-label "$LABEL" 2>/dev/null
         echo "  Issue #$CARD → PR #$PR: added '$LABEL'"
         CHANGED=true
       fi
     done
     
     # Clean up contradictions: remove awaiting-* if approved-* exists
     for PAIR in "awaiting-visual-qa:visual-qa-approved" "awaiting-code-review:code-review-approved"; do
       AWAIT="${PAIR%%:*}"
       APPROVED="${PAIR##*:}"
       ALL_LABELS="$PR_LABELS $ISSUE_LABELS"
       if echo "$ALL_LABELS" | jq -e --arg a "$APPROVED" 'any(. == $a)' &>/dev/null; then
         gh pr edit "$PR" --repo amonick12/helix --remove-label "$AWAIT" 2>/dev/null
         gh issue edit "$CARD" --repo amonick12/helix --remove-label "$AWAIT" 2>/dev/null
       fi
     done
     
     if [[ "$CHANGED" == "false" ]]; then
       echo "PR #$PR ↔ Issue #$CARD: labels in sync"
     fi
   done
   ```
