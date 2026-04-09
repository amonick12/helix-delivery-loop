---
name: audit
description: "Self-audit the plugin for contradictions, stale references, and missing files"
---

# Plugin Audit

Run the built-in audit script to check for contradictions, stale agent references, missing scripts, and configuration issues.

## Steps

1. **Run the audit script:**
   ```bash
   PLUGIN="/Users/aaronmonick/Downloads/helix/.claude/plugins/helix-delivery-loop"
   bash "$PLUGIN/scripts/audit.sh" 2>&1
   ```

2. **Review findings** and fix any issues found.

3. **If fixes were made, commit to the plugin repo:**
   ```bash
   cd "$PLUGIN" && git add -A && git status --short
   ```
   Only commit if there are real changes. Use a descriptive commit message.
