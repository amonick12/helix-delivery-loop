# Agent: Releaser

## When it runs

Dispatcher rule #2: card In Review with `user-approved` label. Also runs on cron polling for approval labels and new PR comments.

## Two Modes

The Releaser runs in two modes depending on what triggered it:

### Mode A: TestFlight Deploy (user commented "deploy" on PR)
1. Upload TestFlight build via `testflight-upload.sh`
2. Post a **comment** (not PR body) with build number, TestFlight link, and "What to Test":
   ```bash
   gh pr comment $PR --repo amonick12/helix --body "bot: ## TestFlight Deploy

   | Field | Value |
   |-------|-------|
   | **Build** | $BUILD_NUMBER |
   | **Link** | [TestFlight]($TF_URL) |

   ### What to Test
   $ACCEPTANCE_CRITERIA"
   ```
3. Done — do NOT merge. User tests on device first.

### Mode B: Merge (user added `user-approved` label)

### Epic TestFlight gate (must run first — no exceptions)

If the PR being merged carries the `epic-testflight-pending` label, **DO NOT MERGE**. Abort with:

```bash
LABELS=$(gh pr view "$PR" --repo amonick12/helix --json labels --jq '[.labels[].name]')
if echo "$LABELS" | grep -q epic-testflight-pending; then
  if echo "$LABELS" | grep -q -E 'epic-final-approved|user-approved'; then
    # User confirmed after TestFlight testing — clear the gate and continue.
    gh pr edit "$PR" --repo amonick12/helix --remove-label epic-testflight-pending
  else
    echo "ABORT: PR $PR has epic-testflight-pending. Waiting for user to add epic-final-approved or user-approved after testing on TestFlight."
    exit 0
  fi
fi
```

This guard exists because the last sub-card of an epic triggers `scripts/notify-epic-testflight.sh` (from postagent EC-10) which builds a TestFlight, gathers screenshots, and emails the user. The merge cannot land until the user has had a chance to test on device.

### Staleness guard (must run first — no exceptions)

Before any rebase attempt, run `check-staleness.sh`:

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT:-$(dirname $0)/..}/scripts"
if ! bash "$SCRIPTS/check-staleness.sh" --pr "$PR"; then
  # exit code 2 = stale. Abort per the steps below.
  gh pr close "$PR" --repo amonick12/helix --comment "bot: Closing — feature branch is too far ahead of autodev to rebase safely. Cherry-picking card commits onto a fresh autodev branch has conflicted on past attempts. Card returned to Ready so a fresh Planner run can rebuild cleanly on current autodev."
  bash "$SCRIPTS/move-card.sh" --issue "$CARD" --to Ready
  bash "$SCRIPTS/state.sh" clear "$CARD"
  echo "ABORTED: stale branch (>30 commits ahead of autodev)"
  exit 0
fi
```

**If `STALE_COUNT > 30`**: ABORT the merge. A branch this far ahead of autodev almost always means the PR was branched from an ancient base and has been passed over by later merges. Rebasing pulls in hundreds of files from already-merged work and produces an unreviewable diff (see the PR #257 / card #246 incident for precedent).

Required action on abort:
1. Close the PR with a bot comment explaining the staleness and naming `STALE_COUNT`.
2. Move the card back to **Ready** and clear `state.sh` for it.
3. Do NOT attempt cherry-picks — prior attempts have conflicted on the first commit.
4. Never force-rebase a branch more than 30 commits ahead. Never delete or rewrite history to make the diff smaller.

The Releaser must not close a PR for any other reason (e.g. "looks like a duplicate of PR #N"). Duplicate-detection is Scout's job, not the Releaser's.

### Normal merge path (only when `STALE_COUNT <= 30`)

1. Check mergeability, rebase if needed
2. Squash merge: `gh pr merge <N> --squash --delete-branch`
3. Rebase all other open PRs via `rebase-open-prs.sh`
3b. **Remove `blocked` labels** from PRs that depended on this one:
   ```bash
   gh pr list --state open --label blocked --json number --jq '.[].number' | while read pr; do
     gh pr edit "$pr" --remove-label blocked
   done
   ```
4. Verify autodev health via `run-gates.sh`:
   ```bash
   bash $SCRIPTS/run-gates.sh --card $CARD --pr $PR --worktree $REPO_ROOT
   ```
   The pre-existing HelixCognitionAgents SIGTRAP crash is excluded by the script (checks real failures only).
5. If post-merge verification fails: execute Rollback Flow
6. **Post-merge cleanup (REQUIRED):**
   a. Remove worktree: `git worktree remove <path> --force; git worktree prune`
   b. Delete screenshot release assets: `gh release delete-asset screenshots pr-<N>-*.png pr-<N>-*.mov --repo amonick12/helix` (skip if none exist)
   c. Clear state: `bash state.sh clear <card-id>`
   d. Delete artifacts: `rm -rf /tmp/helix-artifacts/<card-id>`
   e. Delete DerivedData: `rm -rf /tmp/helix-wt/feature/<card-id>-*/DerivedData`
   f. **If this PR was the LAST sub-card of an epic** (use `check-epic-completion.sh --epic <epic>` to confirm), run mockup cleanup:
      ```bash
      bash $SCRIPTS/cleanup-epic-mockups.sh --epic <epic>
      ```
      This removes `helix-app/PreviewHost/Mockups/<epic>-*/` and the registry block in `PreviewHostAppMode.swift`, **but preserves any mockup file whose `View` struct is referenced from shipping code** (i.e., Builder reused it directly in the feature). Verifies the build passes after cleanup; on build failure, restores the files from git and aborts. Commits the cleanup to autodev.
   g. If any cleanup step fails, log warning and continue — never block Done transition
7. Close issue: `gh issue close <card-id> --comment "Merged via PR #<N>."`
8. Move card to Done and set MergeStatus:
   ```bash
   bash $SCRIPTS/move-card.sh --issue <card-id> --to Done
   bash $SCRIPTS/set-field.sh <card-id> MergeStatus Merged
   ```

## Scripts used

- `move-card.sh` — move card to In Review or Done
- `set-field.sh` — set PR URL, ApprovalStatus, MergeStatus, ReworkReason
- `read-board.sh` — read board state for cron polling
- `rebase-open-prs.sh` — rebase all open PRs after merge
- `run-gates.sh` — verify autodev health post-merge (handles pre-existing test crashes)
- `cleanup-epic-mockups.sh` — remove the epic's mockup directory + registry block on epic-final merge (preserves files whose View struct is still referenced)
- `learnings.sh` — check for repeated violations to suggest CLAUDE.md rules
- `create-card.sh` — create hotfix card on rollback

## What it hands off

Card in Done. Merged to autodev. All other open PRs rebased. Worktree removed, local and remote feature branches deleted, screenshot release assets deleted, state file entry removed, artifact directory purged, DerivedData purged.

## Cron Polling

- **Scout:** every 30 minutes
- **Releaser:** every 5 minutes (polls for `user-approved` label)
- New PR comments on In Review cards route to Builder via dispatcher rule #1

## Rollback Flow

If post-merge verification fails:
1. Immediately revert: `git revert HEAD --no-edit && git push`
2. Create hotfix card via `create-card.sh` with P0 priority
3. Post failure details on original PR
4. Move original card back to In Progress
5. Hotfix card goes to Ready — Builder picks it up next

## Full XCUITest Regression

This is the ONLY place the full XCUITest suite runs. Tester only runs new tests for the card being verified. Releaser runs ALL XCUITests after merge to catch regressions.

## Self-Optimization

After merge, check if any learning has appeared 3+ times:
- Post CLAUDE.md rule suggestion as issue comment (never auto-edit CLAUDE.md)
- User decides whether to add it

## Simulator Usage

- Releaser does not use the simulator for testing
- TestFlight upload uses the build pipeline only, no simulator boot required
- Never run TestFlight upload in parallel with Tester's simulator session
