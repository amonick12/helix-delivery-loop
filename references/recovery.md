# Recovery Runbook

Procedures for recovering the delivery loop from common failure states.

## /tmp Wiped (Reboot, Disk Cleanup)

**Symptoms:** Worktrees missing, artifacts gone, simulator lock stale, state file references dead paths.

**Recovery:**
1. Run `validate-board.sh` to confirm board is healthy
2. Reconstruct worktrees from existing feature branches:
   ```bash
   bash $SCRIPTS/recover.sh --worktrees
   ```
   This finds all `feature/*` branches with open PRs and re-creates their worktrees.
3. Artifacts (specs, plans) are re-fetched from card comments on next agent prepare.
4. State file auto-heals — `list-inflight` purges stale entries, `postagent.sh` fixes stuck states.

**What's lost permanently:** Nothing critical. Specs/plans exist in git (committed by Planner). Screenshots exist as GitHub release assets. The board is the source of truth.

## Simulator Lock Stuck

**Symptoms:** Tester/Scout dispatch fails with "Simulator lock timeout."

**Recovery:**
```bash
rm -rf /tmp/helix-simulator.lock
xcrun simctl shutdown all
```

The lock has a 30-minute TTL auto-expiry, so this should self-heal. If it recurs, check for zombie xcodebuild processes:
```bash
pkill -f "xcodebuild.*helix-wt"
pkill -f "simctl"
```

## Card Stuck in "In Progress" With No Active Agent

**Symptoms:** Card shows In Progress on the board but no agent is running on it. Dispatcher skips it because it doesn't match any rule.

**Diagnosis:**
```bash
bash $SCRIPTS/state.sh list-inflight  # Should be empty for this card
bash $SCRIPTS/read-board.sh --card-id <N> | jq '.cards[0]'  # Check PR state
```

**Common causes and fixes:**

| State | Cause | Fix |
|-------|-------|-----|
| No PR exists | Planner crashed before creating PR | Move card back to Ready: `bash $SCRIPTS/move-card.sh --issue N --to Ready` |
| Draft PR, no labels | Builder crashed mid-work | Builder will pick it up on next dispatch (rule #5) |
| Ready PR, no review labels | Builder marked ready but Reviewer hasn't run | Reviewer will pick it up (rule #4a) |
| Ready PR + code-review-approved + visual-qa-approved, no tests-passed | postagent self-heal should fix | Run: `bash $SCRIPTS/postagent.sh --agent tester --card N --exit-code 0` |
| Ready PR + tests-passed but still In Progress | postagent EC-9 should fix | Run: `bash $SCRIPTS/move-card.sh --issue N --to "In review"` |

## GitHub API Rate Limit Hit

**Symptoms:** `read-board.sh` fails, dispatch returns empty, gh commands fail with 403.

**Recovery:**
1. Check rate limit: `gh api rate_limit --jq '.rate'`
2. Wait for reset: the `reset` field shows UTC timestamp
3. The `gh_retry` wrapper in config.sh automatically retries with backoff — usually self-heals within 30s
4. If persistent: increase `BOARD_CACHE_TTL` in config.sh to reduce API calls

## Designer Mockup Build Fails

**Symptoms:** `generate-design.sh` exits non-zero with `Build failed`, or the simulator screenshot is empty.

**Recovery:**
1. Reproduce the build directly:
   ```bash
   bash devtools/ios-agent/build.sh
   ```
   Read the error. Usually the new SwiftUI mockup file references a token, modifier, or view that doesn't exist (`.glassCard()` typo, missing `import HelixDesignSystem`, etc.).
2. Fix the offending file in `helix-app/PreviewHost/Mockups/<epic>-<slug>/`. Re-run the build.
3. If the build passes but the screenshot is blank, the simulator likely launched into the chrome-mode `PreviewHost` instead of the fixture. Verify the panel id is registered in `PreviewHostScreen.all` and matches the `MOCKUP_FIXTURE` value exactly:
   ```bash
   grep -n 'PreviewHostScreen(id: "<panel-id>"' helix-app/PreviewHost/PreviewHostAppMode.swift
   ```
4. If the panel is registered but the env var isn't reaching the app, verify `launch-app.sh` propagates `MOCKUP_FIXTURE` (it should pass `-MOCKUP_FIXTURE` or set it via `simctl spawn`). If not, set it explicitly:
   ```bash
   xcrun simctl launch --terminate-running-process \
     "$SIMULATOR_UDID" com.amonick.helix \
     MOCKUP_FIXTURE=<panel-id>
   ```
5. After fixing, re-run `generate-design.sh --issue <N> --panels <ids> --regenerate` to capture and post a fresh set.

## Dead-Lettered Card (3+ Failures)

**Symptoms:** Card has `dead-letter` label, dispatcher skips it.

**Recovery:**
1. Read failure history: `bash $SCRIPTS/dispatch-log.sh failures --card N`
2. Fix the root cause (usually in the card's acceptance criteria or a code conflict)
3. Remove label: `gh issue edit N --remove-label dead-letter --repo amonick12/helix`
4. Reset retry counter: `bash $SCRIPTS/state.sh set N retry_count_<agent> 0`
5. Card will be picked up on next dispatch

## In-Flight Registry Shows Stale Agent

**Symptoms:** `state.sh list-inflight` shows an agent that's not actually running. New dispatches for that card are blocked.

**Recovery:**
The registry auto-purges entries older than the agent's time budget (30min for Builder, 10min for Reviewer, etc.). To force-clear:
```bash
bash $SCRIPTS/state.sh deregister-inflight <card-id> <agent>
```

## Board Schema Changed

**Symptoms:** `set-field.sh` fails silently, cards don't move, fields don't update.

**Recovery:**
1. Run validation: `bash $SCRIPTS/validate-board.sh`
2. If field IDs changed, update `config.sh` with the new IDs from the validation output
3. If columns were renamed, update the `STATUS_*` option IDs in config.sh

## Worktree Conflict With Another Branch

**Symptoms:** `git worktree add` fails because path already exists.

**Recovery:**
```bash
# List all worktrees
git worktree list

# Remove the conflicting worktree
git worktree remove /tmp/helix-wt/feature/<card-id>-<slug> --force
git worktree prune

# The Planner will re-create on next dispatch
```
