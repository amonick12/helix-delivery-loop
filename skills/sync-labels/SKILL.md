---
name: sync-labels
description: >
  Sync approval labels (user-approved, ai-approved, code-review-approved,
  visual-qa-approved) between PRs and their linked issues. Cleans up
  contradictory label pairs (awaiting + approved).
---

Use the `/sync-labels` command to invoke this skill. Pass a PR number or omit to sync all open PRs.
