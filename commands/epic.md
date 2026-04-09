---
name: epic
description: "Create a multi-card epic (PRD + sub-cards) from a feature description"
arguments:
  - name: description
    description: "Feature description — what it does, why it matters, rough scope"
    required: true
---

# Epic

Create a PRD and a set of linked sub-cards from a user's feature description.

## Steps

1. **Understand the feature.** Read the user's description and determine:
   - **Feature name:** concise (used as PRD title)
   - **Problem:** what user problem this solves
   - **Vision:** what the experience looks like when done
   - **Priority:** P0-P3 (default P2)

2. **Scan codebase and existing work.** Before creating anything:
   ```bash
   SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
   # Search the codebase for related implementations
   grep -rn '<feature keywords>' Packages/Feature*/Sources/ Packages/Helix*/Sources/ --include='*.swift' | head -20
   # Check for existing PRDs or cards covering this feature
   gh issue list --repo "$REPO" --label prd --search "<keywords>" --limit 5
   gh issue list --repo "$REPO" --search "<keywords>" --state all --limit 10
   ```
   - If substantially covered by existing cards, tell the user and stop
   - Identify which packages, views, and services already exist that the feature will build on
   - Use these concrete references in the PRD and sub-card bodies

3. **Break the feature into cards.** Decompose into individually deployable units:
   - Each card should be completable in one Builder cycle
   - Identify dependencies between cards (which must finish first)
   - Classify each as feature/bug/refactor
   - Note which cards have UI changes

4. **Create sub-cards first** (we need issue numbers for the PRD):
   ```bash
   bash "$SCRIPTS/create-card.sh" \
     --title "<card-title>" \
     --body "<card-body-with-acceptance-criteria>" \
     --priority <P0-P3> \
     --labels "<type-label>,<feature-area-label>"
   ```
   - Each card body includes: Problem, Proposed Solution, Acceptance Criteria
   - Never create standalone "write tests" cards — tests are part of each card's PR
   - If a card depends on another, note it in the body (BlockedBy will be set by Designer)

5. **Write the PRD to the repo** (not a GitHub issue):
   ```bash
   FIRST_CARD=<lowest-card-number>
   SLUG=<feature-slug>
   mkdir -p docs/epics/${FIRST_CARD}-${SLUG}/cards/
   # Create card subdirectories
   for card_num in <card-numbers>; do
     mkdir -p docs/epics/${FIRST_CARD}-${SLUG}/cards/${card_num}-<card-slug>/
   done
   ```
   Write `docs/epics/${FIRST_CARD}-${SLUG}/prd.md` with:
   ```markdown
   # PRD: <Feature Name>

   **Epic:** #<first-card>
   **Cards:** #N, #N+1, ...

   ## Problem
   ## Vision
   ## Architecture
   ## Cards (table with issue numbers, types, dependencies)
   ## Build Order
   ## Non-Goals
   ```
   Add `PRD: docs/epics/<id>-<slug>/prd.md` to each card body as a comment.

6. **Commit the PRD directly to autodev** so all card worktrees can read it:
   ```bash
   git checkout autodev
   git add docs/epics/
   git commit -m "docs: add PRD for <feature-name> epic"
   git push origin autodev
   ```
   This must happen before any card is worked on — the PRD is a reference doc, not a feature.

7. **Report to user** with a summary table:
   | Issue | Title | Type | Status |
   |-------|-------|------|--------|
   | #N | Card 1 title | feature | Backlog |
   | #N+1 | Card 2 title | feature | Backlog |
   | — | PRD | docs | `docs/epics/<id>-<slug>/prd.md` |

## Guidelines

- Default to P2 priority unless the user indicates urgency.
- Each card should be scoped to 1-2 days of Builder work.
- Cards with UI changes will be picked up by Designer automatically (dispatcher rule #7).
- Don't set HasUIChanges — Designer evaluates that.
- Keep card titles under 60 characters, action-oriented ("Add X to Y", "Fix Z in W").
- Include clear acceptance criteria on every sub-card (checkboxes).
- Reference specific Helix packages/views from the architecture when possible.
- If the feature is small enough for a single card, suggest using `/new-card` instead.
