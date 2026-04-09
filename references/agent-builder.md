# Agent: Builder

## When it runs

Dispatcher rule #5: card In Progress with `handoff_from: planner` and `handoff_ready: true`. Also rule #3 on rework: `rework_target: builder`.

## Epic Guard

If the card has the `epic` label, STOP immediately. Epics must be broken into sub-cards by the Planner — they are never built as a single PR. Post a comment: "bot: Cannot build epic card directly. Routing back to Planner to break into sub-cards." Then signal rework to planner.

## What it does (step by step)

1. **Check for `epic` label** — if epic, follow Epic Guard above and stop
2. Read state file to find worktree path
2. cd to `/tmp/helix-wt/feature/<card-id>-<slug>`
3. Check for conflicts with other open PRs via `check-conflicts.sh`
4. Read Planner's test suite (`Packages/*/Tests/*`)
5. Read the spec and design docs:
   - Check `docs/epics/*/cards/<card-id>-*/spec.md` first (epic card)
   - Fall back to `docs/cards/<card-id>-*/spec.md` (standalone card)
   - If epic card, also read the parent `docs/epics/*/prd.md` for context
   - If UI card, read `design.md` from the same directory for mockup references
   - If no spec.md found, fall back to card comments from Planner
6. Implement code to make ALL failing tests pass, following CLAUDE.md patterns strictly
7. Run unit tests frequently during implementation
8. When all tests pass, run automated self-review:
   ```bash
   bash $SCRIPTS/builder-self-review.sh --worktree $WORKTREE
   ```
   Fix any P1 violations before committing. Then:
   - If card has `HasUIChanges=Yes`: write XCUITests and verify UI requirements:
     ```bash
     bash $SCRIPTS/verify-ui-requirements.sh --card $CARD --worktree $WORKTREE
     ```
     Fix any missing requirements (XCUITests, fixture data).
   - Commit all changes
9. Create PR via `create-pr.sh`
10. Run all quality gates (build, unit tests, package tests, SwiftLint, static checks):
    ```bash
    bash $SCRIPTS/run-gates.sh --card $CARD --pr $PR --worktree $WORKTREE
    ```
    All gates must pass. If any fail, fix the code, commit, push, and re-run until clean.
    Results are written to `/tmp/helix-artifacts/<card>/gates.json` with the commit SHA —
    the dispatcher checks this before dispatching Reviewer/Tester.
11. Post handoff comment: files changed, implementation notes, known risks
11. Signal completion via `run-agent.sh finish builder --card N` — this validates the handoff (checks PR exists), tracks token usage, posts cost, and chains to the next agent

## Scripts used

- `check-conflicts.sh` — detect potential merge conflicts with other open PRs
- `builder-self-review.sh` — scan diff for CLAUDE.md violations before commit
- `verify-ui-requirements.sh` — validate XCUITests and fixture data for UI cards
- `create-pr.sh` — create PR with structured template, checklist, card field updates
- `run-gates.sh` — run all deterministic quality gates (build, tests, lint, static checks)
- `learnings.sh` — query patterns from previous cards

## What it hands off

Feature branch with all tests passing, PR created. Reviewer/Tester picks up from here.

## Rework Mode

When picking up `rework_target: builder`:
1. Read ReworkReason from card
2. Read Reviewer/Tester's feedback (PR/card comment)
3. Fix specific issues
4. Clear `rework_target` in state file
5. Re-run tests, commit, push
6. Signal handoff back to Reviewer/Tester

## Self-Review Checklist

Before committing, verify:
- `do/catch` on `modelContext.save()` (never `try?`)
- `Task { @MainActor in }` for async (never `DispatchQueue`)
- Typography from `helixFont` (never hardcoded fonts)
- `SettingsService` `access(keyPath:)` / `withMutation(keyPath:)` hooks
- `accessibilityLabel` on all interactive elements
- No hardcoded strings (localization)
- New tests use Swift Testing (`import Testing`, `@Test`, `@Suite`, `#expect`) — never `XCTest`/`XCTestCase`
- Snapshot tests for new/modified views (if HasUIChanges=Yes)
- Documentation updated in the same commit (see Documentation section below)

## Documentation

Per CLAUDE.md rule #6, docs must be updated in the same commit as the code change. Before committing:

1. **README.md** — update if the feature adds a new user-visible capability or changes a public API
2. **`docs/plans/`** — update the active blueprint doc if the change advances or diverges from the migration plan
3. **Inline comments** — remove or update any comments in touched files that no longer match the code
4. **CLAUDE.md** — update if the change introduces a new architectural pattern, critical file, or constraint that future agents must know about

What does NOT need a doc update: internal refactors with no behavior change, test-only changes, bug fixes that don't alter documented behavior.

## XCUITests (UI changes only)

If the card has `HasUIChanges=Yes`, the Builder writes XCUITests as part of implementation:

1. Write XCUITests in `helix-appUITests/` exercising all new UI actions
2. Register test files: `bash register-uitest.sh --file <path> --worktree <worktree>`
3. Build-for-testing to verify compilation: `xcodebuild build-for-testing -scheme helix-appUITests -destination 'platform=macOS'`
4. Commit XCUITests with the implementation code

The Reviewer/Tester still RUNS the XCUITests on the simulator and captures evidence.

## Snapshot Tests (UI changes)

For UI cards, the Builder adds snapshot tests using [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) to catch visual regressions in unit tests (no simulator needed).

1. Add `swift-snapshot-testing` as a test dependency to the feature package if not already present:
   ```swift
   .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0")
   // In test target:
   .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
   ```
2. Write snapshot tests for each new/modified view in the package's `Tests/` directory:
   ```swift
   import SnapshotTesting
   import SwiftUI
   import Testing

   @Suite struct MyViewSnapshotTests {
       @Test func defaultState() {
           let view = MyView(viewModel: .mock)
           assertSnapshot(of: view, as: .image(layout: .device(config: .iPhone13Pro)))
       }
       @Test func emptyState() {
           let view = MyView(viewModel: .emptyMock)
           assertSnapshot(of: view, as: .image(layout: .device(config: .iPhone13Pro)))
       }
   }
   ```
3. First run generates reference images in `__Snapshots__/` — commit these with the feature code
4. Subsequent runs diff against references — any visual change fails the test
5. Snapshot tests run on macOS alongside unit tests — fast, no simulator boot

Snapshot tests catch layout/font/color regressions early. The Tester's XCUITest screenshots on the real simulator remain the authoritative Visual QA evidence.

## Fake Data / Seed Data (MANDATORY for UI cards)

For UI cards (HasUIChanges=Yes), the Builder MUST:
1. Check if the fixture includes data for the new feature's models (e.g., look in `Packages/HelixHarness/Sources/HelixHarness/` for fixture definitions)
2. If missing: add seed data to the fixture on the feature branch — this is part of the feature, not a separate task
3. Verify the feature renders with data by running the relevant unit tests
4. This is a BLOCKING requirement — do not open the PR without seed data for UI features
5. Include seed data changes in the same commit as the feature code

Fixture reference:
- `FAKE_FIXTURE` env var controls which fixture loads: `empty`, `anxiety_01`, `gratitude_01`, `seeded_20_entries`, `seeded_90_entries`
- Always test with both `empty` (empty state) and a populated fixture
- Screenshots showing empty sections when data should exist = the fixture needs updating, not a passing gate

## SwiftLint (MANDATORY before push)

Run SwiftLint on all changed files before committing. `run-gates.sh` checks this, but catching errors early saves time.

```bash
# Get changed Swift files (exclude tests)
CHANGED=$(cd <worktree> && git diff --name-only origin/autodev...HEAD -- '*.swift' | grep -v Tests/)

# Lint them
echo "$CHANGED" | xargs swiftlint lint --config .swiftlint.yml --quiet

# If errors: fix them, then re-run until clean
```

Common fixes:
- `no_hardcoded_font` → use `helixFont` instead of `.font(...)`
- `no_gcd` → use `Task { @MainActor in }` instead of `DispatchQueue`
- `accessibility_label_required` → add `.accessibilityLabel()` to interactive elements
- `do_catch_on_save` → use `do/catch` not `try?` on `modelContext.save()`

Do NOT push with lint errors. `run-gates.sh` will fail and block the Reviewer/Tester from being dispatched.

## No Simulator Needed

Unit tests on macOS only. Simulator verification is Reviewer/Tester's job.
