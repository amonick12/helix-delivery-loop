---
name: delivery-loop
description: >
  Continuous multi-agent delivery loop for Helix iOS app. Use /delivery-loop
  to dispatch. Eight agents: Scout (PRDs), Maintainer (code integrity), Designer (mockups),
  Planner (spec+TDD), Builder (implementation), Reviewer (Codex CLI code review),
  Tester (deterministic pipeline + Visual QA), Releaser (merge + TestFlight on-demand).
---

Use the `/delivery-loop` command to invoke this skill. See the command for full dispatch logic.

## Agent Quick Reference

| Agent | Model | Dispatch Rule | Role |
|-------|-------|---------------|------|
| **Scout** | Sonnet | #8 (idle, mode=scout) | Product strategy, PRDs, card creation |
| **Maintainer** | Opus | #8 (idle, mode=maintainer) | Code integrity, bugs, arch violations |
| **Designer** | Sonnet | #7 (Backlog, no HasUIChanges) | UI evaluation, Stitch mockups, moves to Ready |
| **Planner** | Opus | #6 (Ready, WIP < 6) | Spec, failing tests (TDD red), draft PR |
| **Builder** | Opus | #3/#5 (draft PR) | Implementation, quality gates, marks PR ready |
| **Reviewer** | Haiku | #4a (ready PR, no code-review-approved) | Codex CLI code review, routes to Builder |
| **Tester** | Sonnet | #4b (ready PR, code-review-approved, UI) | UITests + Visual QA, routes to Builder |
| **Releaser** | Haiku | #1a (deploy) / #2 (user-approved) | TestFlight upload, merge, rebase, cleanup |

## Key behaviors

- **Reviewer uses Codex CLI** (OpenAI) for independent code review, orchestrated by Haiku
- **Tester is deterministic** — `run-tester.sh` handles build/test/screenshot, LLM only does Visual QA
- **TestFlight is on-demand** — user comments "deploy" on a PR, Releaser uploads (not a merge gate)
- **Epic cards require approval** — `epic-approved` label before sub-cards can be created
- **PRs target autodev** — never main. PostToolUse hook auto-corrects
- **All agent comments prefixed with `bot:`**
- **Screenshots come from xcresult** — not manual simctl install (which fails)
- **Onboarding cards use `empty` fixture** — not `seeded_20_entries` (bypasses onboarding)
- **idb is available** for UI interaction alongside XCUITest

## Label flow

- **Reviewer** applies `code-review-approved`
- **Tester** applies `visual-qa-approved` (UI cards only)
- **postagent EC-1** auto-applies `tests-passed` when all required approvals present
- **User** applies `user-approved` to trigger merge

## Enforcement scripts (hard gates, not suggestions)

| Script | Hook | Blocks |
|--------|------|--------|
| `enforce-simulator.sh` | PreToolUse:Bash | Wrong UDID, missing -only-testing, simctl create, build artifact commits |
| `enforce-pr-base.sh` | PostToolUse:Bash | PRs targeting main (auto-fixes to autodev) |
| `hook-guard.sh` | All hooks | Re-entrancy, profile gating (ECC_HOOK_PROFILE) |
| `validate-simulator.sh` | Tester preflight | Wrong device, multiple devices booted |
| `resolve-uitests.sh` | Tester preflight | Returns only branch-changed UITest targets |
| `validate-epic.sh` | create-card.sh | Sub-cards without epic-approved label |
| `validate-pr-labels.sh` | postagent.sh | Contradictory labels (awaiting + approved, rework + approved) |
| `validate-planner-output.sh` | Manual | Planner modifying source files |
| `security-scan.sh` | Reviewer preflight | Hardcoded secrets, insecure HTTP, sensitive UserDefaults |

## Self-healing (postagent.sh)

- **EC-1**: Cards with all required approvals but missing `tests-passed` → auto-applies
  - Non-UI: `code-review-approved` sufficient
  - UI: `code-review-approved` + `visual-qa-approved` required
- **EC-9**: Cards with `tests-passed` stuck in In Progress → moves to In Review
- **Labels**: Fixes contradictory label pairs automatically
- **Simulator lock**: 30-minute TTL auto-expires stale locks
- **In-flight registry**: Auto-purges entries older than agent time budget
- **Zombie processes**: Kills orphaned xcodebuild/simctl after each agent

## Key references

- Scripts: `${CLAUDE_PLUGIN_ROOT}/scripts/`
- Agent docs: `${CLAUDE_PLUGIN_ROOT}/agents/`
- Quality gates: `${CLAUDE_PLUGIN_ROOT}/references/quality-gates.md`
- Self-audit: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/audit.sh`
- Learning evolution: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/learnings.sh evolve`
