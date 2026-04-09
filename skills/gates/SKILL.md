---
name: gates
description: >
  Run quality gates (build, unit tests, package tests, SwiftLint, static checks)
  for a card's PR branch. Auto-fixes the known HelixCognitionAgents SIGTRAP
  false failure when package tests pass but unit tests fail.
---

Use the `/gates <card>` command to invoke this skill.
