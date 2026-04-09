---
name: new-card
description: "Create a new delivery board card from a user request"
arguments:
  - name: description
    description: "What the user wants — feature idea, bug report, or task description"
    required: true
---

# New Card

Translate the user's request into a structured card on the delivery board.

## Steps

1. **Scan the codebase for context.** Before writing anything:
   - Search for existing implementations related to the request:
     ```bash
     grep -rn '<keywords>' Packages/Feature*/Sources/ Packages/Helix*/Sources/ --include='*.swift' | head -20
     ```
   - Check if the feature/fix already exists (if so, tell the user and stop)
   - Identify the specific packages, views, and services that will be involved
   - Reference these in the card body so the Planner has concrete starting points
   - Check existing issues: `gh issue list --repo "$REPO" --search "<keywords>" --state all --limit 5`

2. **Understand the request.** Read the user's description and determine:
   - **Type:** feature, bug, refactor, or chore
   - **Title:** concise, action-oriented (e.g. "Add voice journaling", "Fix crash on journal tab")
   - **Priority:** P0 (critical/blocking), P1 (important), P2 (normal), P3 (nice-to-have)
   - **Severity:** same scale, based on user impact
   - **Blast radius:** Low (one view), Med (one feature), High (cross-feature)
   - **Labels:** comma-separated (e.g. "feature,journal" or "bug,insights")

3. **Write the issue body.** Use this structure:
   ```markdown
   ## Problem
   What's wrong or missing.

   ## Proposed Solution
   High-level approach. Reference specific packages/views from the codebase scan.

   ## Acceptance Criteria
   - [ ] Criterion 1
   - [ ] Criterion 2

   ## Notes
   Any context from the user's request.
   ```

4. **Create the card:**
   ```bash
   SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
   bash "$SCRIPTS/create-card.sh" \
     --title "<title>" \
     --body "<body>" \
     --priority <P0-P3> \
     --severity <P0-P3> \
     --blast-radius <Low|Med|High> \
     --labels "<labels>"
   ```

5. **Confirm to the user** with the issue number, URL, and a summary of what was created.

## Guidelines

- Default to P2/P2/Low if the user doesn't indicate urgency.
- For bugs, include reproduction steps in the body if the user provided them.
- For features, reference relevant existing views/packages from the Helix architecture.
- Keep titles under 60 characters.
- Always add the type label (feature, bug, refactor, chore).
