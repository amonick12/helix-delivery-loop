# helix-delivery-loop

Continuous multi-agent delivery pipeline for the [Helix](https://github.com/amonick12/helix) iOS app. A [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code) that operates on a GitHub Project board with a Kanban workflow.

## Pipeline

```
Scout → Designer → Planner → Builder → Reviewer → Tester → Releaser
```

| Agent | Model | Role |
|-------|-------|------|
| **Scout** | Sonnet | Product strategist — writes PRDs, creates epic and bug cards |
| **Maintainer** | Opus | Codebase health — refactors, tech debt, dependency updates |
| **Designer** | Sonnet | Evaluates UI impact, generates [Stitch](https://stitch.withgoogle.com) mockups, refines acceptance criteria |
| **Planner** | Opus | Writes technical spec, failing tests (TDD red phase), breaks epics into sub-cards |
| **Builder** | Opus | Implements code to pass all tests, runs quality gates, creates PR |
| **Reviewer** | Haiku | Code review via Codex CLI — checks CLAUDE.md compliance, posts findings |
| **Tester** | Sonnet | Visual QA — runs XCUITests on simulator, captures screenshots, compares to mockups |
| **Releaser** | Haiku | Merges approved PRs, rebases open branches, uploads to TestFlight, cleans up |

## Board Columns

| Column | Description |
|--------|-------------|
| **Backlog** | Proposed work — Designer evaluates and adds mockups |
| **Ready** | Designed and prioritized — Planner picks up next |
| **In Progress** | Active work — Planner, Builder, Reviewer, or Tester operating |
| **In Review** | PR exists, all quality gates passed, awaiting user approval |
| **Done** | Merged, verified, released |

## Commands

| Command | Description |
|---------|-------------|
| `/delivery-loop` | Auto-dispatch next agent(s) based on board state |
| `/status` | Show board state, open PRs, active agents, stuck cards |
| `/approve <pr>` | Approve a PR — adds `user-approved`, triggers Releaser |
| `/reject <pr> <reason>` | Reject a PR — posts feedback, routes back to Builder |
| `/deploy [pr]` | Upload PR branch to TestFlight |
| `/maintainer` | Run Maintainer agent — codebase health, refactors, tech debt |
| `/gates <card>` | Run quality gates, auto-fix known false failures |
| `/health` | Pipeline health check — labels, gates, state, conflicts |
| `/sync-labels` | Sync approval labels between PRs and issues |
| `/unstick <card>` | Diagnose and fix a stuck card |
| `/rebase` | Rebase all open PRs on autodev after a merge |
| `/cleanup` | Remove stale worktrees, branches, and artifacts |
| `/audit` | Self-audit plugin for contradictions and stale references |
| `/metrics` | Delivery stats — throughput, costs, cycle times |
| `/new-card <desc>` | Create a new card from a description |
| `/epic <desc>` | Create a multi-card epic with PRD |

## Dispatcher Priority

Evaluated top to bottom, first match wins:

1. Active PR has new user comments → Builder
2. Card In Review with `user-approved` label → Releaser
3. Card In Progress with `rework` label → Target agent
4a. Card In Progress with ready PR, no code review → Reviewer
4b. Card In Progress with code review passed, UI card → Tester
5. Card In Progress with `handoff_from: planner` → Builder
6. Card in Ready (WIP < 4) → Planner
7. Card in Backlog without `HasUIChanges` set → Designer
8. Nothing else → Scout

## Quality Gates

**Builder gates** (before push):
- Build passes (`xcodebuild`)
- Unit tests pass
- Package tests pass
- SwiftLint — 0 new errors
- Static checks (coverage, @Model changes, TODOs)

**Reviewer gate:** LLM code review against CLAUDE.md rules

**Tester gates:** XCUITest screenshots + LLM vision comparison to mockups

## Epic Workflow

Epics are never built as a single PR. The pipeline enforces:

1. **Scout** creates the epic card with a PRD
2. **Designer** designs all screens together
3. **Planner** breaks the epic into sub-cards (one PR each)
4. Each sub-card goes through the full pipeline independently
5. Builder and Planner reject epic-labeled cards with guards

## Design System

Mockups are generated via [Google Stitch](https://stitch.withgoogle.com) with the **Helix Dark** design system:

| Token | Value |
|-------|-------|
| Background | Ocean gradient `#081030` → `#000514` (user-configurable) |
| Accent | Indigo `#5856D6` (user-configurable) |
| Glass cards | `.ultraThinMaterial`, 16pt radius, 0.5pt border |
| Font | Inter |
| Stitch Project | `4588124996861941974` |
| Design System | `15540506800766488887` |

## Setup

1. Clone into your Helix project's plugin directory:
   ```bash
   git clone git@github.com:amonick12/helix-delivery-loop.git \
     .claude/plugins/helix-delivery-loop
   ```

2. Symlink the cache (so Claude Code finds it):
   ```bash
   mkdir -p ~/.claude/plugins/cache/local/helix-delivery-loop
   ln -s "$(pwd)/.claude/plugins/helix-delivery-loop" \
     ~/.claude/plugins/cache/local/helix-delivery-loop/3.0.0
   ```

3. Initialize the project board:
   ```
   /delivery-loop init
   ```

## Requirements

- [Claude Code](https://claude.ai/claude-code) CLI
- [GitHub CLI](https://cli.github.com/) (`gh`) with project scopes
- [Google Cloud SDK](https://cloud.google.com/sdk) (`gcloud`) for Stitch mockups
- Xcode 26+ with iPhone 17 Pro simulator
- App Store Connect API key (for TestFlight uploads)

## Architecture

```
commands/          Slash commands (/delivery-loop, /deploy, /health, etc.)
agents/            Agent frontmatter stubs (model, description)
references/        Agent runtime instructions (single source of truth)
scripts/           Bash scripts for deterministic operations
skills/            Skill definitions
hooks/             Event hooks (pre/post tool use)
tests/             Script tests
```

Agent definitions live in `references/agent-*.md`. The `agents/*.md` files are thin stubs with only YAML frontmatter — all behavioral content is in references to prevent duplication and drift.
