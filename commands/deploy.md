---
name: deploy
description: "Upload a PR branch to TestFlight for testing"
arguments:
  - name: pr
    description: "PR number to deploy (defaults to latest ai-approved PR with UI changes)"
    required: false
---

# Deploy to TestFlight

Upload a feature branch to TestFlight for user testing.

## Steps

1. **Find the PR to deploy:**
   ```bash
   PR_NUMBER="$ARGUMENTS"
   if [[ -z "$PR_NUMBER" ]]; then
     # Find latest ai-approved PR with UI changes
     PR_NUMBER=$(gh pr list --repo amonick12/helix --state open --label "ai-approved" --json number,title --jq '.[0].number' 2>/dev/null)
   fi
   ```
   If no PR found, report "No ai-approved PRs to deploy" and stop.

2. **Get PR details:**
   ```bash
   PR_INFO=$(gh pr view $PR_NUMBER --repo amonick12/helix --json headRefName,title,number --jq '{branch: .headRefName, title: .title, number: .number}')
   BRANCH=$(echo "$PR_INFO" | jq -r '.branch')
   CARD=$(echo "$BRANCH" | grep -oE '[0-9]+' | head -1)
   ```

3. **Ensure worktree exists:**
   ```bash
   WORKTREE="/tmp/helix-wt/$BRANCH"
   if [[ ! -d "$WORKTREE" ]]; then
     git fetch origin "$BRANCH" 2>/dev/null
     git worktree add "$WORKTREE" "$BRANCH" 2>/dev/null
   fi
   ```

4. **Compute build number and upload:**
   ```bash
   LOOP_COUNT=0
   SCRIPTS="/Users/aaronmonick/.claude/plugins/cache/local/helix-delivery-loop/3.0.0/scripts"
   # Check state for loop count
   LOOP_COUNT=$(bash "$SCRIPTS/state.sh" get "$CARD" loop_count 2>/dev/null || echo "0")
   [[ -z "$LOOP_COUNT" || "$LOOP_COUNT" == "null" ]] && LOOP_COUNT=0
   BUILD_NUM=$(( CARD * 100 + LOOP_COUNT ))
   
   cd "$WORKTREE" && ./devtools/ios-agent/testflight-upload.sh --card-id "$CARD" --build-number "$BUILD_NUM" 2>&1
   ```
   Run this with a Bash timeout of 600000ms (10 minutes) since archive + upload takes time.

5. **On success — update PR description:**
   ```bash
   TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
   
   # Get acceptance criteria from card
   CRITERIA=$(gh issue view "$CARD" --repo amonick12/helix --json body --jq '.body' 2>/dev/null | grep -E '^\s*-\s*\[' | head -10)
   
   # Add TestFlight section to PR body
   CURRENT_BODY=$(gh pr view "$PR_NUMBER" --repo amonick12/helix --json body --jq '.body' 2>/dev/null)
   # Strip existing TestFlight section
   CLEAN_BODY=$(echo "$CURRENT_BODY" | sed '/^## TestFlight/,$d' | sed -e :a -e '/^\n*$/{$d;N;ba}')
   
   TF_SECTION="## TestFlight

   - **Build:** \`$BUILD_NUM\`
   - Uploaded: \`$TIMESTAMP\`

   ### What to Test
   $CRITERIA

   Build is processing in App Store Connect. Available in TestFlight within ~15 minutes."
   
   gh pr edit "$PR_NUMBER" --repo amonick12/helix --body "$CLEAN_BODY

   $TF_SECTION"
   ```

6. **On failure — report the error.** Do not block or retry. Show the error output so the user can diagnose.

## Notes
- TestFlight requires App Store Connect API key configured
- Build number formula: `(card_number * 100) + loop_count`
- Archive + upload typically takes 5-8 minutes
- The build processes in App Store Connect for ~15 minutes after upload before appearing in TestFlight
