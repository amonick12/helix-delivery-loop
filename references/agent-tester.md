# Agent: Tester

## When it runs

Dispatcher rule #4b: card In Progress with a **ready PR** (not draft), has `code-review-approved` label, no `visual-qa-approved` label, and card has UI changes.

**Only runs for UI cards.** Non-UI cards skip directly from Reviewer to `ai-approved`.

## What it does

The Tester has TWO phases:

### Phase 1: Deterministic Pipeline (run-tester.sh — NO LLM decisions)

Run this FIRST. It handles everything deterministic:

```bash
bash $SCRIPTS/run-tester.sh --card $CARD --pr $PR --worktree $WORKTREE
```

This script:
1. Validates simulator UDID
2. Resolves UITest targets from branch-changed files
3. Boots simulator, builds app
4. Runs ONLY resolved UITest targets
5. Captures screenshots
6. Uploads to GitHub Release
7. Updates PR description with screenshots
8. Applies pass/fail labels based on UITest results
9. Shuts down simulator

**If run-tester.sh exits 0 (PASS):** proceed to Phase 2.
**If run-tester.sh exits non-zero (FAIL):** STOP. The script already routed to Builder.

### Phase 2: Visual QA (LLM — the ONLY non-deterministic step)

After run-tester.sh succeeds, review the screenshots it posted:

1. Read the PR description to find the uploaded screenshot URLs
2. Read the mockup from the card's DesignURL field
3. Compare screenshots against mockup using your vision capabilities
4. Run the Visual QA checklist below against each screenshot
5. **Check off acceptance criteria:** For each criterion in the PR's Acceptance Criteria section that can be verified visually (e.g., "Progress indicator visible on steps 2-5", "Glass card styling"), check it off:
   ```bash
   bash $SCRIPTS/update-pr-evidence.sh --pr $PR --section checklist --check "<criterion text>"
   ```
   Only check criteria you can confirm from the screenshots. Leave unchecked anything that requires code inspection (that's Reviewer's job).
6. If issues found:
   - Post text-only comment (bot: prefix) describing the issues
   - Convert PR to draft + add rework label: `gh pr ready --undo $PR && gh pr edit $PR --add-label rework --remove-label code-review-approved --remove-label visual-qa-approved --remove-label ai-approved`
7. If all good:
   - Post text-only comment: `bot: ## Visual QA — PASS (verified)`
   - Apply label: `gh pr edit $PR --repo amonick12/helix --add-label visual-qa-approved`

## CRITICAL: No Code Changes

The Tester **NEVER**:
- Edits source files
- Commits or pushes code
- Fixes bugs, typos, or style issues
- Writes or modifies tests
- Runs unit test scripts (run-unit-tests.sh, run-all-package-unit-tests.sh)

## idb

idb is available for UI interaction, screenshots, and accessibility tree inspection alongside XCUITest.

## Visual QA Checklist

Run against EVERY screenshot:

**Layout**
- [ ] All text is left-aligned (not centered unless design explicitly requires it)
- [ ] Cards and cells expand to full container width
- [ ] Consistent spacing between sections
- [ ] No text clipping, truncation, or overflow
- [ ] No overlapping elements

**Design System**
- [ ] Dark gradient background visible
- [ ] Glass card styling on card containers
- [ ] Accent color is helixAccent for interactive elements
- [ ] Typography is consistent hierarchy
- [ ] No font mismatches

**Content**
- [ ] All acceptance criteria states visible
- [ ] Populated state shows real data
- [ ] Empty state handled

## Where Screenshots Go

**Screenshots go ONLY in the PR description (body). Never in comments.**

run-tester.sh handles uploading and updating the PR description automatically.
If you need to update screenshots after Visual QA feedback, use:

```bash
bash $SCRIPTS/update-pr-evidence.sh --pr $PR --section screenshots --content "..."
bash $SCRIPTS/update-pr-evidence.sh --pr $PR --section visual-qa --content "..."
```
