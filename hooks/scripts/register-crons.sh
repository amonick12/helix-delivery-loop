#!/bin/bash
# UserPromptSubmit hook: re-register delivery loop cron jobs once per session.
# Uses PPID as a session identifier — each Claude process gets a unique PID.

FLAG="/tmp/helix-crons-${PPID:-0}"

# Already registered this session — stay silent
[[ -f "$FLAG" ]] && exit 0

touch "$FLAG"

cat <<'MSG'
[HELIX] Delivery loop cron jobs need to be registered for this session. Please register them now using CronCreate before responding to the user:

1. Every 5 minutes — poll for user-approved labels (Releaser) and new PR/issue comments (Builder). Skip Scout:
   cron: "*/5 * * * *"
   prompt: Run the Helix delivery loop poll cycle. Check for actionable work using the dispatcher and dispatch agents if needed. Do NOT run Scout (rule 8) — this is a poll cycle only for: user-approved labels (Releaser), new user PR/issue comments (Builder), rework targets, and CI-passing handoffs (Reviewer/Tester). If the only available action is Scout, do nothing and exit silently. Steps: 1) Run DISPATCH=$(bash /Users/aaronmonick/Downloads/helix/.claude/plugins/helix-delivery-loop/scripts/dispatcher.sh --dry-run --multi 2>/dev/null) 2) Filter out any decision where agent == "scout" 3) If no decisions remain, exit silently 4) For each remaining decision, prepare and launch the agent via run-agent.sh prepare, then launch Agent tool with matching subagent_type (helix-delivery-loop:builder etc) 5) After each agent completes run postagent.sh and run-agent.sh finish

2. Hourly at :17 — Scout discovery sweep (only if nothing else is actionable):
   cron: "17 * * * *"
   prompt: Run the Helix Scout agent for periodic discovery. Steps: 1) Run dispatcher --dry-run, if agent is NOT "scout" exit silently 2) If agent is "scout", prepare and launch via run-agent.sh prepare scout --card 0, then launch Agent tool with subagent_type helix-delivery-loop:scout 3) After Scout completes run postagent.sh and run-agent.sh finish scout --card 0
MSG
