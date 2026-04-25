---
name: delivery-loop
description: "Run the delivery loop — dispatches the next agent automatically based on board state"
arguments:
  - name: subcommand
    description: "Optional: status, scout, maintainer, designer, planner, builder, reviewer, tester, releaser, init, cleanup, metrics"
    required: false
---

# Helix Delivery Loop

Continuous feature delivery driven by the GitHub Project board. Eight phase-based agents operate across a Kanban workflow. All quality gates are fully deterministic (SwiftLint, xcodebuild, test results). LLMs only do creative work (writing code, tests, specs, designs).

**Terminology:**
- **Card** = GitHub Issue on the project board (has acceptance criteria, status column, custom fields)
- **PR** = Pull Request linked to a card (has code changes, checklist, evidence, labels)
- **Issue comments** = comments on the card/issue page
- **PR comments** = comments on the pull request page (code review, validation reports, screenshots)
- Cards and PRs are separate. A card can exist without a PR (Backlog/Ready). A PR always references a card (`Closes #N`).

## On Every Invocation

**Every time this command is invoked, DO THIS:**

1. **Drain the approval queue.** Bookkeeping (queue scan, retry counter, sentinels, dead-letter escalation, label flips, dispatch-log entries) is owned by `scripts/drain-emails.sh`. The orchestrator only does the two things shell can't: spawn a subagent for vision QA, and fire `PushNotification` to alert the user that an approval is queued. **No Gmail send.** The user already gets an email automatically from GitHub when Designer/Tester/Releaser posts the panels/screenshots comment on the issue or PR — that's the persistent email channel; we just add an instant push-notification on top.

   ```bash
   # First: surface the Gmail-MCP-down sentinel loudly if it exists.
   [[ -f /tmp/helix-gmail-mcp-down ]] && cat /tmp/helix-gmail-mcp-down

   # Then ask the script for a structured plan.
   PLAN=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/drain-emails.sh" plan)
   ```

   For each entry in `PLAN`:

   - `action: "vision_qa"` — spawn a fresh subagent (Explore or general-purpose) with this prompt and the entry's `screenshots[]`:
     > Read each URL with vision and score against the Helix Quality Bar in `references/vision-qa-prompt.md`. Return JSON: `{"all_pass": bool, "panels": [{"url":"...", "pass": bool, "failures":["..."]}]}`. No prose, JSON only.

     Then call back into the script:
     - If `all_pass: true` → `bash $SCRIPTS/drain-emails.sh mark-vision-pass --file <file> --note "<one-line summary>"`
     - If `all_pass: false` → `bash $SCRIPTS/drain-emails.sh mark-vision-fail --file <file> --failures '<json array of failure strings>'`

     The script handles retry counting, dead-letter escalation at retries ≥ 3, label flips (`redesign-needed`, `rework`), PR draft conversion, and dispatch-log entries.

   - `action: "send"` — vision QA passed; alert the user. **Do NOT call Gmail MCP** (no `send_message` tool exists, and Gmail's `create_draft` would just clutter Drafts). The actual approval-content-bearing email arrives automatically from GitHub when Designer/Tester/Releaser posts the panels/screenshots comment on the issue or PR (the user is subscribed to issues they own). Just fire `PushNotification` with `status: "proactive"` and a one-line message naming the card + the label they need to add. Then `bash $SCRIPTS/drain-emails.sh mark-sent --file <file>`. PushNotification suppression ("terminal has focus") is fine — mark sent anyway.

   Re-run `drain-emails.sh plan` once more after acting on every entry — vision-QA passes turn into sends; one drain cycle handles both stages. Do NOT skip this step even if the plan looks empty; it's cheap.

2. Check for new PR comments:
   ```bash
   SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
   NEW_COMMENTS=$(bash "$SCRIPTS/check-pr-comments.sh" 2>/dev/null)
   ```
   If there are new user comments, read them and report before dispatching.

2. Run the **multi-dispatcher** to get ALL parallelizable agents at once:
   ```bash
   DISPATCH=$(bash "$SCRIPTS/dispatcher.sh" --dry-run --multi 2>/dev/null)
   DECISIONS=$(echo "$DISPATCH" | jq '.decisions')
   COUNT=$(echo "$DECISIONS" | jq 'length')
   ```

3. If there are decisions, prepare and launch ALL agents in parallel:
   - For each decision in DECISIONS:
     ```bash
     AGENT=$(echo "$d" | jq -r '.agent')
     CARD=$(echo "$d" | jq -r '.card')
     PROMPT=$(bash "$SCRIPTS/run-agent.sh" prepare $AGENT --card $CARD 2>/dev/null)
     ```
   - Launch ALL Agent tools **in a single message** (multiple tool calls) so they run concurrently.
   - Non-simulator agents (Designer, Planner, Reviewer) can run alongside simulator agents (Tester, Releaser, Scout).
   - The dispatcher already enforces: at most one simulator agent, no duplicate cards.

4. As each agent completes (you get notified), run postagent + finish for that specific agent:
   ```bash
   EXIT_CODE=$?
   bash "$SCRIPTS/postagent.sh" --agent $AGENT --card $CARD --exit-code $EXIT_CODE --duration $SECONDS
   bash "$SCRIPTS/run-agent.sh" finish $AGENT --card $CARD
   ```
   Do this for EACH agent independently as it completes.

   **CRITICAL — Post-agent column transitions (NEVER skip gates):**

   | Agent Finished | Card HasUIChanges | Labels Applied | Move card to |
   |---|---|---|---|
   | Builder | any | (none yet) | **Keep In Progress** — Reviewer next |
   | Reviewer (PASS) | **No** (non-UI) | `code-review-approved` | **In Review** — ready for user approval |
   | Reviewer (PASS) | **Yes** (UI) | `code-review-approved` only | **Keep In Progress** — Tester must run next for visual QA |
   | Reviewer (FAIL) | any | `rework` | **Keep In Progress** — Builder rework |
   | Tester (PASS) | Yes | `visual-qa-approved` | **In Review** — ready for user approval |
   | Tester (FAIL) | Yes | `rework` | **Keep In Progress** — Builder rework |
   | Releaser | any | merged | **Done** |

   **NEVER move a UI card to In Review after Reviewer passes.** UI cards require Tester visual QA (screenshots/recordings) before they're user-reviewable. Skipping Tester means the user approves a PR with no visual evidence.

   **How to tell if a card is UI:** Check if the PR diff touches any `.swift` file under `Views/` or if the card body contains "HasUIChanges: Yes". Non-UI cards are pure logic/service/model changes.

5. After ANY agent completes, immediately re-dispatch to check for new parallel-safe work:
   ```bash
   DISPATCH=$(bash "$SCRIPTS/dispatcher.sh" --dry-run --multi 2>/dev/null)
   ```
   The in-flight registry automatically tracks running agents, so the dispatcher won't double-dispatch.
   Launch any new agents that appear. Continue until all agents finish and no new work is available.

**Do NOT wait for user input between dispatches. Do NOT ask what to do. Just dispatch.**

**Never open a PR for an epic artifact alone.** PRDs (`docs/epics/<id>-<slug>/prd.md`), epic issue bodies, or any other epic-scoped change must NOT get a standalone branch or PR. The PRD file rides along with the first sub-card's implementation PR (see `references/agent-builder.md` → PRD Inclusion Rule). This applies to the orchestrator (this command) as well as to every agent.

**CONTINUOUS DISPATCH — NEVER GO IDLE:**

The orchestrator must never respond with "waiting for completions" or "pipeline idle" while work exists. Between agent launches and user messages, aggressively re-dispatch. The rules are:

1. **After every agent completion notification**, immediately re-run the dispatcher and launch any new actionable agents in the same response — do not just acknowledge and stop.
2. **If the multi-dispatcher returns empty but the board has Ready cards**, fall back to single-dispatch mode and check each rule manually. Ready cards with pushed feature branches but no PR should route to Builder (rule 5 with the handoff-gap fix).
3. **If the dispatcher still returns nothing**, manually prepare and launch agents for:
   - Cards In Progress whose Planner has pushed a branch (Builder to create PR)
   - Cards In Progress with ready PRs + code-review-approved but no visual-qa-approved (Tester)
   - Cards In Review with `user-approved` label (Releaser)
   - Cards in Ready that have dependencies satisfied (Planner/Builder for dependents can branch from parent)
4. **Never say "waiting for completions".** If agents are running in background, launch additional parallel work (non-simulator agents, or work on different cards). The only reason to stop dispatching is:
   - Every card on the board is In Review awaiting user approval
   - All running agents are exclusive (simulator lock) and no non-simulator work exists
5. **On every response** (including cron, user messages, completion notifications), the first action is always: check dispatcher → prepare agents → launch. Not "check status then report idle".

Only respond with "No actionable cards" when: Backlog=0, Ready=0, all In Progress have running agents, all In Review have `user-approved` pending.

**Fallback:** If `--multi` is not working, you can fall back to the single-dispatch mode:
   ```bash
   DISPATCH=$(bash "$SCRIPTS/dispatcher.sh" --dry-run 2>/dev/null)
   ```
   This returns a single `{agent, card, reason, model}` JSON and works exactly as before.

## Subcommands

| Subcommand | Action |
|------------|--------|
| *(none)* | Auto-dispatch next agent |
| `status` | Show board state + next recommended action |
| `scout` | Run Scout agent (discovery sweep) |
| `maintainer` | Run Maintainer agent (code integrity sweep) |
| `designer` | Run Designer agent (design phase) |
| `planner` | Run Planner agent (spec + TDD) |
| `builder` | Run Builder agent (implementation) |
| `reviewer` | Run Reviewer agent (code review) |
| `tester` | Run Tester agent (UITests + Visual QA) |
| `releaser` | Run Releaser agent (merge + release) |
| `init` | Bootstrap project board, fields, columns, screenshots release |
| `cleanup` | Remove stale worktrees for Done cards |
| `metrics` | Delivery health stats |
| `audit` | Self-consistency check: terminology, agent count, permissions, versions, two-approval contract |
| `trace <card>` | Full timeline for one card — dispatches, postagent runs, GitHub events, email queue |
| `evolve` | Cluster learnings into actionable rules with confidence scores |

## Agent Pipeline

```
Scout (epic proposals) → Designer (mockups) → Planner (spec + TDD + cards) → Builder → Reviewer (code review) → Tester (Visual QA) → Releaser
```

| Agent | Model | Role |
|-------|-------|------|
| **Scout** | Sonnet | Product strategist: writes PRDs, breaks into cards, creates bug cards |
| **Maintainer** | Opus | Code integrity: finds bugs, race conditions, arch violations, missing tests |
| **Designer** | Opus | Evaluates UI impact, posts the Helix Design System Brief, materializes Claude Design handoff bundles |
| **Planner** | Opus | Writes technical spec, failing unit tests (TDD red phase), implementation plan |
| **Builder** | Opus (Sonnet on rework) | Implements using spec + tests + plan + mockups; runs SwiftLint before push |
| **Reviewer** | Haiku | Code review via Codex CLI — review only, never modifies code, no simulator |
| **Tester** | Sonnet | UITests + Visual QA — runs simulator, captures screenshots, never modifies code |
| **Releaser** | Haiku | Merges approved PRs, rebases open branches, cleans up worktrees/artifacts/state |

## Board Columns

| Column | Description |
|--------|-------------|
| **Backlog** | Proposed work; Designer adds mockups here before moving to Ready |
| **Ready** | Designed and prioritized; ready for Planner |
| **In Progress** | Active work — Planner, Builder, Reviewer, or Tester operating |
| **In Review** | PR exists, all quality gates passed, awaiting user approval |
| **Done** | Merged, verified, and released |

## Dispatcher Priority Rules

Implemented in `scripts/dispatcher.sh`. Evaluated top to bottom, first match wins.

| # | Condition | Agent |
|---|-----------|-------|
| 1a | Active PR has user comment "deploy" | Releaser (TestFlight only, no merge) |
| 1b | Active PR has other new user comments | Builder |
| 2 | Card In Review with `user-approved` label | Releaser (merge) |
| 3 | Card In Progress with draft PR + `rework` label | Builder |
| 4a | Card In Progress with ready PR + no `code-review-approved` | Reviewer |
| 4b | Card In Progress with ready PR + `code-review-approved` + UI card + no `visual-qa-approved` | Tester |
| 5 | Card In Progress with draft PR (no `rework` label) | Builder |
| 6 | Card in Ready (respect WIP limit) | Planner |
| 7 | Card in Backlog without `HasUIChanges` set | Designer |
| 7c | UI card in Backlog with a user comment newer than the latest `bot:` Designer post | Designer (regenerate) |
| 7b | Epic in Backlog with user `approve` / `epic-approved` comment | Move to Ready + Planner |
| 8 | Nothing else to do | Scout or Maintainer (based on `idle_mode` setting, default: scout) |

**Priority ordering:** P0 > P1 > P2 > P3. Ties broken by issue number (oldest first).

**Blocked/dead-lettered cards:** Skipped automatically by `filter_blocked()`.

**WIP enforcement:** Rule 6 checks `count(In Progress) < 4` before dispatching.

## Handoff Protocol

Agents signal phase transitions via **PR state** — no state file needed for dispatch.

| PR State | Means | Next Agent |
|----------|-------|------------|
| No PR | Planner working or card in Ready/Backlog | Planner/Designer |
| Draft PR (no `rework` label) | Planner done, Builder picks up | Builder |
| Draft PR + `rework` label | Reviewer/Tester rejected, Builder fixes | Builder |
| Ready PR + no `code-review-approved` | Builder done, Reviewer checks code | Reviewer |
| Ready PR + `code-review-approved` + no `visual-qa-approved` | Code review passed, Tester runs Visual QA | Tester |
| Ready PR + `tests-passed` | All automated gates passed, card moves to In Review | Releaser (after `user-approved`) |

The board column is authoritative. State file tracks loop counts, timers, and intra-phase handoffs for observability. If they conflict, the board column wins.

## Quality Gates

### Builder Gates (`run-gates.sh` — before push)

| Gate | What it checks |
|------|----------------|
| `build` | Build passes (xcodebuild) |
| `unit-tests` | Unit tests pass |
| `package-tests` | Package tests pass |
| `swiftlint` | 0 new lint errors |
| `static-checks` | Coverage, @Model changes, TODO/FIXME (advisory) |

Results written to `gates.json` with commit SHA. Dispatcher auto-reruns if stale.

### Reviewer + Tester Gates (after Builder gates pass)

| Gate | Tool | Skip condition |
|------|------|----------------|
| Code Review | Codex CLI reads diff, checks CLAUDE.md compliance | never |
| Visual QA | LLM vision (compare screenshots vs mockup) | non-UI card |

**Review-only:** Reviewer and Tester never modify code. They post findings and route blocking issues back to Builder for fixing.

**TestFlight** is on-demand only — user comments "deploy" on a PR to trigger. It is NOT a merge gate.

## Design Flow

Designer works on Backlog cards and moves them to Ready when done. No user review gate on individual card designs.

For **epics**: designs are approved as part of the epic proposal (`epic-approved` label). Individual cards inherit the approved designs.

Non-UI cards skip design entirely — Designer sets `HasUIChanges=No` and moves to Ready.

## Worktree Model

| Aspect | Value |
|--------|-------|
| **Base branch** | `autodev` |
| **Feature branches** | `feature/<card-id>-<slug>` |
| **Location** | `/tmp/helix-wt/feature/<card-id>-<slug>` |
| **Simulator lock** | `acquire_simulator_lock()` / `release_simulator_lock()` |
| **Cleanup** | `worktree.sh cleanup-stale` removes Done >24h |

## WIP Limits

- **Max 4** cards In Progress
- **Max 5** cards In Review

## Cost Tracking

Estimates based on current Anthropic API pricing (Opus $15/$75, Sonnet $3/$15, Haiku $0.80/$4 per 1M input/output tokens) and OpenAI Codex CLI for Reviewer.

| Agent | Default Model | Est. Cost |
|-------|---------------|-----------|
| Scout | Sonnet | $0.30 |
| Maintainer | Opus | $2.50 |
| Designer | Opus | $0.40 |
| Planner | Opus | $2.50 |
| Builder | Opus | $5.00 |
| Reviewer | Haiku + Codex CLI | $0.50 |
| Tester | Sonnet | $0.50 |
| Releaser | Haiku | $0.10 |
| **Total per card** | | **~$11.80** |

Tracked by `scripts/track-usage.sh`. Posted to card field + PR comment.

## Build Numbers

Deterministic: `(issue_number * 100) + loop_count`. No shared counter.

## Constraints

- Only one simulator-using agent at a time (enforced by `acquire_simulator_lock()`)
- Only one simulator device (iPhone 17 Pro Codex)
- Never commit screenshots or recordings to the repo
- Never force-push to `autodev`
- Never merge without `user-approved` label
- Never apply `tests-passed` directly — always use `scripts/apply-tests-passed.sh`
- Real simulator screenshots only (no HTML mockups as evidence)
- idb is available for UI interaction alongside XCUITest and xcrun simctl
- Screen recordings from XCUITests exercising ALL new actions, animations ON
- Before/after screenshots: exact same screen, same scroll position
- `loop_count >= 3` escalates to user

## Reliability System

### Preflight Validation (Layer 1)
Before any agent runs, `scripts/preflight.sh` validates card state, worktrees, handoffs, and labels. On failure, the dispatch is skipped and logged.

### Post-Agent Cleanup (Layer 2)
After every agent run, `scripts/postagent.sh` reconciles state: orphaned worktrees, stale labels, stuck handoff fields, lingering simulators. Cards that fail 3 times are dead-lettered.

### Observability (Layer 3)
`scripts/dispatch-log.sh` records every dispatch cycle as structured JSONL. `scripts/status.sh` shows dead-lettered cards, recent failures, and throughput.

## Reference Docs

- `${CLAUDE_PLUGIN_ROOT}/agents/` — Agent definitions with model frontmatter
- `${CLAUDE_PLUGIN_ROOT}/references/quality-gates.md` — All quality gates and pass criteria
- `${CLAUDE_PLUGIN_ROOT}/references/visual-evidence.md` — Screenshot and recording requirements
- `${CLAUDE_PLUGIN_ROOT}/references/Design.md` — Helix design system tokens used in the Claude Design brief
- `${CLAUDE_PLUGIN_ROOT}/references/card-schema.md` — Card fields and PR template
- `${CLAUDE_PLUGIN_ROOT}/references/testflight.md` — TestFlight distribution workflow
