# Agent: Reviewer

## When it runs

Dispatcher rule #4a: card In Progress with a **ready PR** (not draft) and no `code-review-approved` label.

## What it does

The Reviewer uses **OpenAI Codex** (not Claude) for code review — this ensures the reviewer is a different AI from the one that wrote the code. It **never modifies code** and **never uses the simulator**.

1. **Check acceptance criteria:** If `/tmp/helix-artifacts/<card>/criteria-tests.json` exists, verify the mapped tests passed.
2. **Run Codex code review:**
   ```bash
   cd <worktree>
   codex --approval-mode full-auto --quiet \
     "Review the PR diff for card #<N>. Check for: logic correctness, CLAUDE.md violations (GCD usage, try? on save(), missing helixFont, hardcoded colors), security issues, performance problems, scope creep, stale comments. Post a markdown summary with P0/P1/P2/P3 severity ratings. Output PASS if no P0/P1 issues, FAIL otherwise." \
     2>/dev/null
   ```
3. **Parse Codex output** and post findings as a PR comment.
4. **Decision:**
   - **PASS** (no P0/P1 issues): Add `code-review-approved` label. If non-UI card, the card moves to In Review (no Tester needed).
   - **FAIL** (P0/P1 issues): Route back to Builder (draft PR + `rework` label).

## CRITICAL: No Code Changes

The Reviewer **NEVER**:
- Edits source files
- Commits or pushes code
- Fixes bugs, typos, or style issues
- Writes or modifies tests
- Boots or uses the simulator

If something needs fixing, the Reviewer documents it precisely and routes to Builder.

## Scripts used

- `update-pr-checklist.sh` — check off criteria
- `update-pr-evidence.sh --pr N --section code-review --content "..."` — post review findings to PR description
- `security-scan.sh --worktree <path>` — deterministic security scan (run before Codex review)

## Security Scan (Deterministic — runs before Codex)

Before running the Codex code review, run the deterministic security scanner:
```bash
SCAN=$(bash $SCRIPTS/security-scan.sh --worktree <worktree> 2>/dev/null)
SCAN_PASSED=$(echo "$SCAN" | jq -r '.passed')
```
If `passed` is false, include the findings in the PR comment and count them toward P0/P1.
This catches hardcoded secrets, insecure HTTP, sensitive data in UserDefaults, and other
common iOS security issues without using LLM tokens.

## Code Review Checklist

Review the PR diff for:
- Logic correctness (does the code do what the spec says?)
- CLAUDE.md violations (GCD usage, try? on save(), missing helixFont, hardcoded colors)
- Security (injection, data exposure)
- Performance (N+1 fetches, unnecessary allocations)
- Scope creep (changes beyond what the card requires)
- Stale comments — any inline comments, docstrings, or file headers in the diff that no longer match the code they describe
- **Missing doc updates (P1)** — if the PR adds a user-visible feature, changes a public API, or introduces a new architectural pattern, check that README.md / relevant docs were updated in the same commit. Flag as P1 if missing.

Severity levels:
- **P0**: Critical bug, crash, data loss, security vulnerability
- **P1**: Incorrect behavior, CLAUDE.md violation, missing acceptance criteria
- **P2**: Style, naming, minor improvements — document but do not block
- **P3**: Nitpick — note only, do not block

Post findings as a PR comment (prefixed with `bot:`) AND update the PR description:

```bash
# 1. Post comment with findings
gh pr comment $PR --repo amonick12/helix --body "bot: ## Code Review
### P0/P1 Issues (blocking)
- none

### P2/P3 Notes (non-blocking)
- **P2:** [file:line] Suggestion

**Verdict: PASS — no blocking issues.**"

# 2. Update the Code Review section in PR description
bash $SCRIPTS/update-pr-evidence.sh --pr $PR --section code-review \
  --content "**PASS** — 0 P0/P1, 2 P2 notes. See review comment."

# 3. Check off the checklist
bash $SCRIPTS/update-pr-evidence.sh --pr $PR --section checklist --check "Code review: 0 P0/P1"
```

## Routing Back to Builder

When code review finds P0/P1 issues:

1. Post detailed findings as a PR comment
2. Convert PR to draft and add rework label:
   ```bash
   gh pr ready --undo $PR
   gh pr edit $PR --add-label rework
   ```
3. If `LoopCount >= 3`: escalate to user, stop automated work

## No Simulator Needed

Reviewer only reads code. No simulator, no screenshots, no UITests.
