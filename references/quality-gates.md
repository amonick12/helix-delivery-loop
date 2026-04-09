# Quality Gates & Rework Loops

## Gate Ownership

| Owner | Gates | How |
|-------|-------|-----|
| **Builder** | Build, unit tests, package tests, SwiftLint, static checks | Runs `run-gates.sh` before push. Results in `gates.json`. |
| **Reviewer Agent** | Code review | Dispatched after Builder gates pass. Uses Codex CLI. Review-only — never modifies code, no simulator. |
| **Tester Agent** | Visual QA (if UI) | Dispatched after code review passes. Uses simulator + vision API. Review-only — never modifies code. |

## Builder Gates (`run-gates.sh`)

Builder runs all deterministic gates locally before pushing. Results are written to `/tmp/helix-artifacts/<card>/gates.json` with the commit SHA. The dispatcher checks this file and auto-reruns if the commit doesn't match PR HEAD.

| Gate | What it checks | Pass criteria |
|------|---------------|---------------|
| `build` | `xcodebuild build` | Exit code 0 |
| `unit-tests` | `xcodebuild test -skip-testing:helix-appUITests` | 0 failures |
| `package-tests` | `run-all-package-unit-tests.sh` | 0 failures (pre-existing signal 5 crash excluded) |
| `swiftlint` | SwiftLint on changed files, diff-filtered | 0 new errors |
| `static-checks` | Coverage baseline, @Model changes, TODO/FIXME | Advisory warnings, non-blocking |
| `uitest-compilation` | `xcodebuild build-for-testing` on UITest files | Exit code 0 (skipped if no UITest files in diff) |
| `snapshot-tests` | `swift-snapshot-testing` visual regression | 0 failures (skipped if no packages use it yet) |

## Reviewer + Tester Gates

Dispatched by the dispatcher after Builder gates pass. Both are **review-only** — they never modify code.

### Reviewer Gate: Code Review

Read the PR diff and review for:
- Logic correctness (does the code do what the spec says?)
- CLAUDE.md violations (GCD usage, try? on save(), missing helixFont, hardcoded colors)
- Security (injection, data exposure)
- Performance (N+1 fetches, unnecessary allocations)
- Scope creep (changes beyond what the card requires)
- Missing documentation updates

**Pass criteria:** 0 unresolved P0/P1 findings. P2/P3 documented but not blocking.

**On P0/P1 findings:** Reviewer posts detailed findings and routes to Builder. Never self-heals.

### Tester Gate: Visual QA (UI cards only)

Single-pass review — Tester takes screenshots and screen recording, compares against mockup + acceptance criteria via vision API, posts findings. If issues found, routes to Builder with specific details.

**Pass criteria:** All acceptance criteria visually verified, no design system violations, screenshots and recording posted to PR description with `Visual QA — PASS`.

## TestFlight (On-Demand, Not a Gate)

TestFlight is **not a merge requirement**. It only runs when the user comments `deploy` on a PR.

When triggered, the Releaser uploads to TestFlight and posts a comment with the build number and link. The merge flow proceeds independently — `user-approved` triggers merge regardless of whether a TestFlight build was requested.

Build number formula: `(issue_number * 100) + loop_count`.

---

## PR Checklist

Every PR has a quality gate checklist managed by `update-pr-checklist.sh`:

- [ ] Builder gates passing (build, tests, lint, UITest compilation, snapshot tests)
- [ ] Code review: 0 P0/P1
- [ ] Visual QA pass (if UI)

`apply-tests-passed.sh` enforces all checked + visual evidence before applying the `tests-passed` label.

### Label Flow

- **Reviewer** applies `code-review-approved` after code review passes
- **Tester** applies `visual-qa-approved` after Visual QA passes (UI cards only)
- **postagent.sh (EC-1)** detects when all required approvals are present and auto-applies `tests-passed`:
  - Non-UI cards: `code-review-approved` alone is sufficient
  - UI cards: `code-review-approved` + `visual-qa-approved` both required
- **User** applies `user-approved` to trigger merge

---

## Severity Levels

| Severity | Description | Action |
|----------|-------------|--------|
| **P0** | Critical: crash, data loss, security breach | Blocks. Reviewer/Tester routes to Builder immediately. |
| **P1** | High: broken feature, broken existing flow | Blocks. Reviewer/Tester routes to Builder. |
| **P2** | Medium: degraded UX, missing edge case | Document in PR comment. Do not block. |
| **P3** | Low: style nit, minor inconsistency | Note only. |

**Routing rules:**
- Route to **Builder** for all code fixes (P0/P1 issues, user PR comment feedback, Visual QA failures)
- Route to **Designer** only for visual mismatches that require a redesign decision
- Never route P2 or P3 — document and continue

---

## Rework Loops

Each rework cycle increments `LoopCount` on the card.

### Verification Failure
1. Reviewer/Tester posts detailed findings as PR comment
2. Sets `ReworkReason`, increments `LoopCount`, routes to Builder
3. Builder fixes issues, pushes, re-runs `run-gates.sh` — Reviewer re-dispatches

### User Feedback (PR Comments)
1. Dispatcher routes to Builder (rule #1)
2. Builder reads the comment and addresses the change request
3. Reviewer re-reviews after Builder pushes

### Excessive Loop Escalation
**Trigger:** `LoopCount >= 3`
1. STOP all agent work on this card
2. Post escalation comment with summary of all attempts + root cause analysis
3. Wait for user decision before resuming

---

## Gate Failure Quick Reference

| Failure | Who Fixes | How |
|---------|-----------|-----|
| Build/test/lint fails | Builder | Fix code, re-run `run-gates.sh` |
| Code review P0/P1 | Builder (routed by Reviewer/Tester) | Reviewer/Tester posts findings, Builder fixes |
| Visual QA finds issues | Builder (routed by Reviewer/Tester) | Reviewer/Tester posts findings with screenshots, Builder fixes |
| Visual mismatch needs redesign | Designer | Reviewer/Tester routes with specific mismatch details |
| Implementation architecture issue | Builder | Reviewer/Tester routes with `rework_target: builder` |
| LoopCount >= 3 | User decision | Stop, escalate, wait |
