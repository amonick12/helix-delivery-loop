# Agent: Planner

## When it runs

Dispatcher rule #6: card in Ready column (respects WIP limit of 4 In Progress).

## Epic Rule (NON-NEGOTIABLE)

If the card has the `epic` label, the Planner MUST NOT write tests or a spec for the epic itself. Instead:

1. Read the PRD and acceptance criteria
2. Break the epic into **sub-cards** — each sub-card is one PR-sized unit of work
3. Create sub-cards via `scripts/create-card.sh` with:
   - Clear title referencing the epic (e.g., "Insights v2: Weekly summary hero card")
   - Acceptance criteria scoped to that sub-card only
   - Link to parent epic in the body (`Part of #<epic-id>`)
4. Post the breakdown as an epic comment listing all sub-cards
5. Move the epic card to Done (it's now a tracking issue, not a buildable card)
6. The sub-cards enter Backlog → Designer evaluates each one individually

**Never plan, spec, or build an epic as a single PR.** Epics are collections of cards, not cards themselves.

## What it does (step by step)

1. **Check for `epic` label first** — if epic, follow the Epic Rule above and stop
2. Read card: acceptance criteria, mockup (if HasUIChanges=Yes), user comments
2. Check for reusable code before designing:
   - Search for existing similar ViewModels/Views/Services in the codebase
   - If a similar component exists, spec should extend it rather than create from scratch
   - Reference the similar component with file path and what can be reused
   - Check `learnings.sh query --agent planner --type pattern` for effective patterns from previous cards
3. Create worktree from autodev:
   - Check if `/tmp/helix-wt/feature/<card-id>-<slug>` exists -> remove if stale
   - `git worktree add /tmp/helix-wt/feature/<card-id>-<slug> -b feature/<card-id>-<slug> autodev`
4. Read relevant existing code to understand patterns and test conventions
5. Estimate card size and post as a comment (S/M/L/XL with file count, criteria count, estimated cost)
6. Write failing unit tests encoding acceptance criteria:
   - Tests in `Packages/*/Tests/*` following existing package test layout
   - Use Swift Testing framework (@Test, #expect, etc.)
   - Tests must be specific to acceptance criteria, not generic coverage
7. Run tests to confirm they FAIL (red phase):
   - `cd /tmp/helix-wt/feature/<card-id>-<slug> && ./devtools/ios-agent/run-unit-tests.sh`
8. Write technical spec and implementation plan to the card's docs directory:
   - Epic cards: `docs/epics/<epic-id>-<slug>/cards/<card-id>-<slug>/spec.md`
   - Standalone cards: `docs/cards/<card-id>-<slug>/spec.md`
   - `spec.md` includes: technical spec (data model, API changes, component design) AND implementation plan (files to create/modify, order, key patterns, what each test expects)
   - Create the directory if it doesn't exist: `mkdir -p docs/epics/.../cards/<card-id>-<slug>` or `mkdir -p docs/cards/<card-id>-<slug>`
   - Also post spec as card comment for visibility (the repo file is authoritative)
9. Create `criteria-tests.json` in the artifact directory (NOT the worktree) mapping each acceptance criterion to its test:
   ```bash
   mkdir -p /tmp/helix-artifacts/<card-id>
   cat > /tmp/helix-artifacts/<card-id>/criteria-tests.json <<'JSON'
   [
     {"criterion": "Insights tab shows a section listing CognitiveAction items", "test": "CognitiveActionListViewModelTests/testLoadActions"},
     {"criterion": "Users can accept a proposed action", "test": "CognitiveActionListViewModelTests/testAcceptAction"},
     {"criterion": "Empty state shown when no actions exist", "test": "CognitiveActionListViewModelTests/testEmptyState"}
   ]
   JSON
   ```
   Each criterion from the card's acceptance criteria maps to exactly one test. Do NOT commit this file — it's a build artifact.
10. Commit failing tests:
   - `git add Packages/*/Tests/*`
   - `git commit -m "test: add failing tests for #<card-id> <description>"`
   - `git push -u origin feature/<card-id>-<slug>`
11. Move card to In Progress, set Branch field
12. Signal handoff: update state file with `handoff_ready: true`, `handoff_from: planner`

## Scripts used

- `move-card.sh` — move card to In Progress
- `set-field.sh` — set Branch field
- `worktree.sh` — create worktree (or use git worktree directly)
- `learnings.sh` — query effective patterns from previous cards

## What it hands off

Worktree at `/tmp/helix-wt/feature/<card-id>-<slug>` with failing tests committed and pushed. Spec committed to `docs/epics/.../cards/<id>-<slug>/spec.md` or `docs/cards/<id>-<slug>/spec.md`. Builder picks up from here.

## Size Estimate Format

```markdown
## Size Estimate — Card #<N>

| Metric | Value |
|--------|-------|
| Acceptance criteria | X |
| Files to create | X |
| Files to modify | X |
| New tests needed | X |
| Estimated agent cost | $X.XX |
| Estimated model | Opus/Sonnet |

Complexity: **S / M / L / XL**
- S: 1-2 files, <3 criteria, ~$3
- M: 3-5 files, 3-5 criteria, ~$7
- L: 6-10 files, 5-8 criteria, ~$12
- XL: 10+ files, 8+ criteria, ~$20+
```

## No Simulator Needed

Runs tests on macOS (default run-unit-tests.sh destination).
