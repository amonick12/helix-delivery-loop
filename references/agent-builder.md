# Agent: Builder

## TL;DR (read first, descend on demand)

1. Confirm card In Progress + worktree exists (preflight has already done this; trust it).
2. Read spec at `/tmp/helix-artifacts/<card>/spec.md`, design at `docs/epics/*/cards/<card>-*/design.md` (if UI), and parent PRD if epic sub-card.
3. **If UI**, locate Designer's mockup view(s) under `helix-app/PreviewHost/Mockups/<epic>-<slug>/<panel>.swift` and copy their structure (modifiers, tokens, copy, SF Symbols) into the shipping feature view; replace sample data with ViewModel bindings. Do not redesign.
4. Implement to make Planner's failing tests pass. Run `builder-self-review.sh`; fix P1 violations.
5. UI cards: write XCUITests for new actions, run `verify-ui-requirements.sh`.
6. Run `run-gates.sh` (build, unit, package, swiftlint, **schema-migration**, static checks). All must pass.
7. Push, mark PR ready, signal handoff via `run-agent.sh finish builder --card N`.
8. **Diff size cap: 500 lines** (excluding `__Snapshots__/*.png` and Xcode-generated). Stop and split if over.

PRD inclusion rule, full quality-gate descriptions, and recovery steps are below — descend only when something fails.

## When it runs

Dispatcher rule #5: card In Progress with `handoff_from: planner` and `handoff_ready: true`. Also rule #3 on rework: `rework_target: builder`.

## Epic Guard

If the card has the `epic` label, STOP immediately. Epics must be broken into sub-cards by the Planner — they are never built as a single PR. Post a comment: "bot: Cannot build epic card directly. Routing back to Planner to break into sub-cards." Then signal rework to planner.

## PRD Inclusion Rule (first sub-card only)

When implementing the **first sub-card of an epic**, include the epic's PRD file (`docs/epics/<epic-id>-<slug>/prd.md`) in this PR's diff if it is not already committed on autodev. Do not open a separate PR for the PRD; do not commit it on a separate branch. If the PRD file does not exist in the current worktree, write it from the epic issue body before staging code changes. Sub-cards 2+ inherit the already-committed PRD and should not re-stage it.

## Package.swift rule (hard — known regression)

Never add files to an explicit `sources: [...]` array in any `Packages/*/Package.swift`. SwiftPM auto-discovers every `.swift` file under `Sources/<target>/` by default, and CLAUDE.md mandates auto-discovery.

**When you touch a package that has an existing explicit `sources:` list:**
- Do NOT extend it. Delete the entire `sources: [...]` argument from the `.target(...)` call instead, so SPM goes back to auto-discovery.
- Verify the delete by building: `swift build --build-tests` from the package directory must still resolve all types.

Reviewers have flagged this as a P1 regression on PRs #273 and #275 (back-to-back). If you find yourself about to add a line to `sources: [...]`, stop — remove the whole list in the same commit instead.

## What it does (step by step)

1. **Check for `epic` label** — if epic, follow Epic Guard above and stop
2. Read state file to find worktree path
2. cd to `/tmp/helix-wt/feature/<card-id>-<slug>`
3. Check for conflicts with other open PRs via `check-conflicts.sh`
4. Read Planner's test suite (`Packages/*/Tests/*`)
5. Read the spec and design docs:
   - Spec lives at `/tmp/helix-artifacts/<card-id>/spec.md` (build artifact written by Planner — never committed)
   - If epic card, also read the parent `docs/epics/*/prd.md` for context
   - If UI card, read `docs/epics/*/cards/<card-id>-*/design.md` for mockup references (design.md IS committed; spec.md is not)
   - If no artifact spec.md found, fall back to card comments from Planner

5b. **If this is a UI sub-card, locate the Designer's SwiftUI mockup view(s)** under `helix-app/PreviewHost/Mockups/<epic>-<slug>/<panel>.swift`. These are not throwaway — Designer rendered them in the simulator, the user approved the resulting screenshots, and the file is the source of truth for layout, component composition, glass-card usage, color/font tokens, spacing, microcopy, SF Symbol choice, and density. Your job:
    1. **Read the mockup view file(s) for the panel(s) this card ships** (the panel ids are listed in the design.md or the card body; if absent, list everything in the epic's mockup directory and pick the file whose name matches the screen this card builds).
    2. **Copy the mockup view's structure** — the SwiftUI hierarchy, modifier chains, glass cards, font/color tokens — into the shipping feature package under `Packages/FeatureXXX/Sources/FeatureXXX/Views/<FeatureView>.swift`.
    3. **Replace the mockup's hardcoded sample data** with bindings to the real ViewModel: `@State`, `@Bindable`, `@Query`, environment objects, etc. The mockup's sample-data values become the realistic empty/loaded states the ViewModel produces.
    4. **Wire navigation, taps, and side effects** the spec describes.
    5. **Do NOT redesign the layout, change spacing, swap components, alter copy, or pick different SF Symbols.** The mockup IS the approved design — your job is to make it work, not to reinterpret it. If the mockup is genuinely impossible to ship as-is (e.g., references a token Helix doesn't have), comment on the card explaining the conflict and request a Designer regeneration via the `redesign-needed` label rather than silently deviating.
    6. After the feature view ships, the mockup file in `PreviewHost/Mockups/` is auto-cleaned by Releaser unless you reused the View struct name/body directly in shipping code (in which case `cleanup-epic-mockups.sh` detects the reference and preserves the mockup file). Either path is fine; just don't drift visually from the approved panels.
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

## PR Size Cap (NON-NEGOTIABLE)

**Every PR must be ≤500 lines (added + removed) excluding generated files and `__Snapshots__/*.png`.** Before opening the PR:

```bash
DIFF_LINES=$(cd $WORKTREE && git diff --shortstat "origin/$BASE_BRANCH...HEAD" -- ':!**/__Snapshots__/*.png' ':!**/*.pbxproj' ':!**/*.xcfilelist' | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
if [[ "$DIFF_LINES" -gt 500 ]]; then
  echo "PR diff is $DIFF_LINES lines (>500 cap). Stop and route back to Planner to split the card."
  exit 1
fi
```

If the diff exceeds 500 lines, do NOT open the PR. Post a comment on the card explaining the size, signal rework back to the Planner, and stop. The Planner is responsible for re-splitting the card. Never bypass this cap by opening the PR anyway — code review at >500 lines is unreliable.

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

## Snapshot Tests (MANDATORY for UI changes)

**Snapshot tests are the PRIMARY source of visual evidence for PRs.** The `.png` files they commit to `__Snapshots__/` are referenced directly in the PR body via `blob/<feature-branch>/path?raw=true` URLs — no release uploads, no separate branch, no Tester-generated runtime screenshots needed. Every UI card MUST add snapshot tests covering every new/modified view and every meaningful state (empty, populated, loading, error).

**CRITICAL — iOS rendering, not macOS:**
Snapshot tests MUST render views in iOS style. Do NOT use `NSHostingView` or macOS-only snapshot strategies — the resulting PNGs will show macOS chrome (menu bar fonts, AppKit buttons, macOS material effects) instead of actual iOS. The correct approach:

1. Use the iOS-native strategy: `.image(layout: .device(config: .iPhone13Pro))` — requires compiling/running tests against an iOS destination.
2. Run tests with the iPhone 17 Pro simulator destination, not the macOS destination:
   ```bash
   xcodebuild test \
     -project helix-app.xcodeproj \
     -scheme <package>Tests \
     -destination 'id=FAB8420B-A062-4973-812A-910024FA3CE1' \
     -only-testing:<package>Tests/<SnapshotTestClass>
   ```
3. The default `run-unit-tests.sh` runs on macOS for speed — DO NOT use it for snapshot tests. Use the iOS simulator destination explicitly.
4. If tests fail with "'image' is unavailable on macOS" or similar, you're running on the wrong destination.

For UI cards, the Builder adds snapshot tests using [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) to catch visual regressions (runs against iOS simulator, not macOS).

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
6. **Post the snapshot images as PR visual evidence** using `update-pr-evidence.sh`:
   ```bash
   SNAPSHOTS=$(find Packages -type d -name "__Snapshots__" -path "*/Tests/*" | xargs -I {} find {} -name "*.png" 2>/dev/null | tr '\n' ' ')
   bash $SCRIPTS/update-pr-evidence.sh --pr $PR --card $CARD --result PASS --screenshots "$SNAPSHOTS"
   ```
   **CRITICAL — Do NOT write your own image URLs in the PR body.** The script uses the `https://raw.githubusercontent.com/<owner>/<repo>/refs/heads/<branch>/<path>` form, which is the ONLY URL form that reliably resolves for private repo branches containing slashes. Any other form (`blob/<branch>/path?raw=true`, `raw.gh/.../feature/xxx/path`, absolute `/tmp/` paths) produces broken URLs. If you need to reference images manually, run the script or copy its exact URL format.

   **BEFORE claiming success, verify URLs resolve:**
   ```bash
   FIRST_URL=$(gh pr view $PR --repo $REPO --json body -q '.body' | grep -oE 'https://raw[^")]+\.png' | head -1)
   curl -sI -H "Authorization: token $(gh auth token)" "$FIRST_URL" | head -1
   # Must print HTTP/2 200 — if not, the URLs are broken and must be fixed before finishing
   ```

Snapshot tests catch layout/font/color regressions early AND serve as the primary visual evidence in the PR description. The Tester agent only runs when a card has interactive behavior that snapshots can't capture (navigation flows, gesture-based interactions).

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
