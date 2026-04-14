---
name: health
description: "Pipeline health check — find label mismatches, missing gates, stale state, conflicts, and stuck cards"
---

# Pipeline Health Check

Comprehensive check for all common pipeline issues. Run this before dispatching or when things seem stuck.

## Steps

1. **Run all checks:**
   ```bash
   SCRIPTS="/Users/aaronmonick/.claude/plugins/cache/local/helix-delivery-loop/3.0.0/scripts"
   ISSUES=()
   
   echo "=== Pipeline Health Check ==="
   echo ""
   
   # ── Open PRs ──────────────────────────────────────
   echo "## Open PRs"
   PRS=$(gh pr list --repo amonick12/helix --state open --json number,title,headRefName,mergeable,labels 2>/dev/null)
   echo "$PRS" | python3 -c "
   import sys, json
   prs = json.load(sys.stdin)
   for pr in prs:
     status = '✅' if pr['mergeable'] == 'MERGEABLE' else '❌ CONFLICTING'
     labels = [l['name'] for l in pr.get('labels',[])]
     print(f\"  PR #{pr['number']} {status} — {pr['title'][:50]}\")
     print(f\"    labels: {labels}\")
   "
   
   # ── Label Mismatches ──────────────────────────────
   echo ""
   echo "## Label Sync"
   SYNC_LABELS=("user-approved")
   echo "$PRS" | python3 -c "
   import sys, json, subprocess
   prs = json.load(sys.stdin)
   for pr in prs:
     branch = pr.get('headRefName','')
     card = ''.join(c for c in branch.split('-')[0].split('/')[-1] if c.isdigit())
     if not card: continue
     pr_labels = set(l['name'] for l in pr.get('labels',[]))
     try:
       result = subprocess.run(['gh','issue','view',card,'--repo','amonick12/helix','--json','labels','--jq','[.labels[].name]'], capture_output=True, text=True)
       issue_labels = set(json.loads(result.stdout))
     except: continue
     for label in ['user-approved','visual-qa-approved','code-review-approved']:
       if label in pr_labels and label not in issue_labels:
         print(f'  ❌ PR #{pr[\"number\"]} has \"{label}\" but issue #{card} does not')
       elif label in issue_labels and label not in pr_labels:
         print(f'  ❌ Issue #{card} has \"{label}\" but PR #{pr[\"number\"]} does not')
     # Check contradictions
     if 'awaiting-visual-qa' in pr_labels and 'visual-qa-approved' in pr_labels:
       print(f'  ❌ PR #{pr[\"number\"]} has both awaiting-visual-qa AND visual-qa-approved')
   print('  (run /sync-labels to fix)')
   "
   
   # ── Board State ───────────────────────────────────
   echo ""
   echo "## Board (non-Done)"
   bash "$SCRIPTS/read-board.sh" --no-cache 2>/dev/null | python3 -c "
   import sys, json
   data = json.load(sys.stdin)
   for card in data.get('cards',[]):
     status = card['fields'].get('Status','?')
     num = card['issue_number']
     title = card['title'][:45]
     labels = card.get('labels',[])
     flags = []
     if 'epic' in labels and status in ('Ready','In progress'):
       flags.append('⚠️  EPIC in pipeline — should be sub-carded')
     print(f'  #{num} [{status}] {title} {\" \".join(flags)}')
   "
   
   # ── Missing Gates ─────────────────────────────────
   echo ""
   echo "## Gates"
   bash "$SCRIPTS/read-board.sh" 2>/dev/null | python3 -c "
   import sys, json, os
   data = json.load(sys.stdin)
   for card in data.get('cards',[]):
     status = card['fields'].get('Status','?')
     num = card['issue_number']
     if status == 'In progress':
       gates_file = f'/tmp/helix-artifacts/{num}/gates.json'
       if os.path.exists(gates_file):
         with open(gates_file) as f:
           g = json.load(f)
         passed = '✅' if g.get('all_pass') else '❌'
         print(f'  #{num}: {passed} gates.json exists (all_pass={g.get(\"all_pass\")})')
       else:
         print(f'  #{num}: ⚠️  No gates.json — run /gates {num}')
   "
   
   # ── Stale State ───────────────────────────────────
   echo ""
   echo "## State File"
   python3 -c "
   import json
   with open('/Users/aaronmonick/Downloads/helix/.claude/delivery-loop-state.json') as f:
     data = json.load(f)
   for cid, state in data.get('cards',{}).items():
     issues = []
     if state.get('rework_target') and state.get('rework_target') not in ('','cleared'):
       issues.append(f'stale rework_target={state[\"rework_target\"]}')
     if state.get('handoff_error'):
       issues.append(f'handoff_error={state[\"handoff_error\"]}')
     if issues:
       print(f'  #{cid}: ⚠️  {\", \".join(issues)} — run /unstick {cid}')
   if not any(s.get('rework_target') or s.get('handoff_error') for s in data.get('cards',{}).values()):
     print('  ✅ No stale state entries')
   "
   
   # ── Worktrees ─────────────────────────────────────
   echo ""
   echo "## Worktrees"
   git worktree list 2>/dev/null | grep helix-wt || echo "  No active worktrees"
   
   # ── Dispatcher ────────────────────────────────────
   echo ""
   echo "## Next Dispatch"
   bash "$SCRIPTS/dispatcher.sh" --dry-run --multi 2>/dev/null | python3 -c "
   import sys, json
   d = json.load(sys.stdin)
   decisions = d.get('decisions',[])
   skipped = d.get('skipped',[])
   if decisions:
     for dec in decisions:
       print(f'  → {dec[\"agent\"]} for #{dec[\"card\"]}: {dec[\"reason\"]}')
   else:
     print('  No actionable work')
   for s in skipped:
     print(f'  ⏭️  #{s[\"card\"]}: {s[\"reason\"]}')
   "
   ```

2. **Summarize findings.** Report total issues found and which `/command` fixes each one.
