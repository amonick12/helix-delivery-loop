# Card Schema & PR Template (v2)

## Columns

The delivery board has six columns. Cards flow left to right.

| Column | Description |
|--------|-------------|
| **Backlog** | Scout-created cards. Designer evaluates UI impact, posts mockups, and moves to Ready. |
| **Ready** | Fully specified cards cleared for implementation. Planner picks these up to produce a plan and branch. |
| **In Progress** | Planner, Builder, Reviewer, and Tester all operate in this column. Planner writes failing tests, Builder implements, Reviewer reviews code, Tester runs Visual QA before promotion. |
| **In Review** | PR is open and awaiting user approval (`user-approved` label). Releaser merges once approved. |
| **Done** | Merged to autodev. Card is closed. |

---

## Card Fields

Every card accumulates fields as it moves through the pipeline. Not all fields are set at creation.

### Text Fields

| Field | Set By | Description |
|-------|--------|-------------|
| **Branch** | Planner | `feature/<card-id>-<slug>` |
| **PR URL** | Releaser | URL to the open pull request |
| **DesignURL** | Designer | Link to a SwiftUI mockup screenshot (rendered from `helix-app/PreviewHost/Mockups/`, uploaded to the `screenshots` GitHub Release) |
| **Evidence URL** | Reviewer/Tester/Releaser | Screenshots, recordings, validation reports |
| **Validation Report URL** | Reviewer | Link to code-review comment on the PR |
| **Risk** | Scout/Builder | Free-text description of implementation risk |
| **ReworkReason** | Reviewer/Tester/Releaser | Why the card was sent back from In Review |
| **BlockedReason** | Any agent | Why the card cannot proceed |

### Select Fields

| Field | Values | Set By |
|-------|--------|--------|
| **Priority** | P0, P1, P2, P3 | Scout (initial); user (override) |
| **Severity** | P0, P1, P2, P3 | Scout |
| **BlastRadius** | Low, Med, High | Scout/Builder |
| **HasUIChanges** | Yes, No | Designer |
| **ApprovalStatus** | Pending, Approved | Releaser (after label check) |
| **MergeStatus** | Pending, Merged, Failed | Releaser |

### Number Fields

| Field | Set By | Description |
|-------|--------|-------------|
| **LoopCount** | Reviewer/Tester | Starts at 0; incremented on each rework cycle |

---

## Branch Naming Convention

All implementation work uses a single branch pattern:

```
feature/<card-id>-<slug>
```

Examples:
```
feature/42-journal-export
feature/57-insight-chat-streaming
```

The branch is created by Planner or Builder when the card enters In Progress. All commits for the card land on this branch. Hotfix branches (post-merge) use `hotfix/<card-id>-<slug>`.

---

## State Transitions

| From | To | Trigger |
|------|----|---------|
| _(none)_ | **Backlog** | Scout creates card, or user manually creates/drops a card |
| **Backlog** | **Ready** | Designer evaluates UI impact, posts mockups (if UI), moves to Ready |
| **Ready** | **In Progress** | Planner picks up card, creates branch and plan |
| **In Progress** | **In Review** | Reviewer + Tester pass all gates; card moves to In Review |
| **In Review** | **Done** | Releaser merges after `user-approved` label is applied |
| **In Review** | **In Progress** | Rework: PR converted to draft, `ReworkReason` set, `LoopCount` incremented |

---

## PR Template

Every PR opened by Releaser must use this template exactly.

```markdown
## Approval Checklist

- [ ] Unit tests pass
- [ ] Package tests pass
- [ ] Code review completed
- [ ] Code coverage maintained or improved
- [ ] XCUITests exercise all new UI actions (UI changes only)
- [ ] Screen recordings posted (UI changes only)
- [ ] Before/after screenshots posted at same scroll position (UI changes only)
- [ ] TestFlight build uploaded (UI changes only)

---

## Summary

- <bullet 1>
- <bullet 2>
- <bullet 3>

## Card

<Link to project board card>

## Before/After Screenshots

<!-- UI changes only. Side-by-side table required. -->

| Before | After |
|--------|-------|
| <screenshot> | <screenshot> |

## Screen Recordings

<!-- UI changes only. Clipped to relevant content, animations ON. -->

## Code Coverage

<!-- Post coverage % here. Must meet or exceed baseline. -->

## Code Review Summary

<!-- Reviewer posts P0/P1 findings and resolutions here. -->
```

---

## Card Lifecycle

The following fields are set (or updated) at each key transition.

| Transition | Fields Set |
|------------|------------|
| **Created → Backlog** | Priority, Severity, BlastRadius, Risk, Evidence URL (mockup/proposal) |
| **Backlog → Ready** | HasUIChanges, DesignURL (if UI card) |
| **Ready → In Progress** | Branch |
| **In Progress → In Review** | PR URL, Validation Report URL, Evidence URL (screenshots/recordings), ApprovalStatus=Pending |
| **In Review → Done** | ApprovalStatus=Approved, MergeStatus=Merged |
| **In Review → In Progress** (rework) | ReworkReason, LoopCount (incremented), MergeStatus=Failed |
