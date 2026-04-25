#!/bin/bash
# rebase-open-prs.sh — Rebase all open PRs against autodev after a merge.
#
# Usage:
#   ./rebase-open-prs.sh [--exclude <pr-number>]
#
# Env:
#   DRY_RUN=1   Skip git operations, print what would happen

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
rebase-open-prs.sh — Rebase all open PRs against autodev after a merge.

Usage:
  ./rebase-open-prs.sh [--exclude <pr-number>]

Options:
  --exclude <N>   PR number to exclude (typically the just-merged PR)

Reports results: which PRs succeeded, which had conflicts.
On conflict: posts a comment on the PR noting the rebase failure.

Env:
  DRY_RUN=1   Skip git operations, print what would happen
HELP

# ── Parse args ─────────────────────────────────────────
EXCLUDE_PR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude) EXCLUDE_PR="$2"; shift 2 ;;
    *)         log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

DRY_RUN="${DRY_RUN:-0}"

# ── Fetch open PRs ────────────────────────────────────
if [[ "$DRY_RUN" == "1" ]]; then
  OPEN_PRS="${MOCK_OPEN_PRS:-[]}"
else
  OPEN_PRS=$(gh pr list --repo "$REPO" --base "$BASE_BRANCH" --state open --json number,headRefName 2>/dev/null || echo "[]")
fi

PR_COUNT=$(echo "$OPEN_PRS" | jq 'length')
if [[ "$PR_COUNT" -eq 0 ]]; then
  log_info "No open PRs to rebase"
  echo '{"rebased":[],"conflicts":[]}'
  exit 0
fi

REBASED="[]"
CONFLICTS="[]"

# ── Fetch latest autodev ──────────────────────────────
if [[ "$DRY_RUN" != "1" ]]; then
  git -C "$HELIX_REPO_ROOT" fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true
fi

# ── Process each PR ───────────────────────────────────
while IFS= read -r pr_json; do
  [[ -z "$pr_json" || "$pr_json" == "null" ]] && continue

  PR_NUM=$(echo "$pr_json" | jq -r '.number')
  BRANCH_NAME=$(echo "$pr_json" | jq -r '.headRefName')

  # Skip excluded PR
  if [[ -n "$EXCLUDE_PR" && "$PR_NUM" == "$EXCLUDE_PR" ]]; then
    log_info "Skipping excluded PR #$PR_NUM"
    continue
  fi

  log_info "Rebasing PR #$PR_NUM ($BRANCH_NAME) against $BASE_BRANCH"

  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[DRY_RUN] Would rebase $BRANCH_NAME against origin/$BASE_BRANCH"
    REBASED=$(echo "$REBASED" | jq --argjson num "$PR_NUM" --arg branch "$BRANCH_NAME" '. + [{number: $num, branch: $branch}]')
    continue
  fi

  # Try to find existing worktree for this branch
  TEMP_WT="/tmp/helix-wt-rebase-$PR_NUM"
  CLEANUP_WT=false

  # Check if there is an existing worktree for this branch
  EXISTING_WT=$(git -C "$HELIX_REPO_ROOT" worktree list --porcelain 2>/dev/null | grep -B1 "branch refs/heads/$BRANCH_NAME" | head -1 | sed 's/^worktree //' || echo "")

  if [[ -n "$EXISTING_WT" && -d "$EXISTING_WT" ]]; then
    WORK_DIR="$EXISTING_WT"
  else
    # Create temp worktree
    git -C "$HELIX_REPO_ROOT" worktree add "$TEMP_WT" "$BRANCH_NAME" 2>/dev/null || {
      # Branch might only exist on remote
      git -C "$HELIX_REPO_ROOT" fetch origin "$BRANCH_NAME" --quiet 2>/dev/null || true
      git -C "$HELIX_REPO_ROOT" worktree add "$TEMP_WT" -b "$BRANCH_NAME" "origin/$BRANCH_NAME" 2>/dev/null || {
        log_warn "Could not create worktree for PR #$PR_NUM ($BRANCH_NAME)"
        CONFLICTS=$(echo "$CONFLICTS" | jq --argjson num "$PR_NUM" --arg branch "$BRANCH_NAME" --arg reason "Could not create worktree" '. + [{number: $num, branch: $branch, reason: $reason}]')
        continue
      }
    }
    WORK_DIR="$TEMP_WT"
    CLEANUP_WT=true
  fi

  # Attempt rebase
  if git -C "$WORK_DIR" rebase "origin/$BASE_BRANCH" 2>/dev/null; then
    # Force push with lease
    if git -C "$WORK_DIR" push --force-with-lease 2>/dev/null; then
      log_info "Successfully rebased PR #$PR_NUM"
      REBASED=$(echo "$REBASED" | jq --argjson num "$PR_NUM" --arg branch "$BRANCH_NAME" '. + [{number: $num, branch: $branch}]')
    else
      log_warn "Rebase succeeded but push failed for PR #$PR_NUM"
      git -C "$WORK_DIR" rebase --abort 2>/dev/null || true
      CONFLICTS=$(echo "$CONFLICTS" | jq --argjson num "$PR_NUM" --arg branch "$BRANCH_NAME" --arg reason "Push failed after rebase" '. + [{number: $num, branch: $branch, reason: $reason}]')
    fi
  else
    log_warn "Rebase conflict on PR #$PR_NUM ($BRANCH_NAME)"
    git -C "$WORK_DIR" rebase --abort 2>/dev/null || true

    # Post comment + label so the dispatcher routes Builder to fix it
    MERGED_PR_NOTE=""
    if [[ -n "$EXCLUDE_PR" ]]; then
      MERGED_PR_NOTE=" after merge of #$EXCLUDE_PR"
    fi
    gh pr comment "$PR_NUM" --repo "$REPO" --body "bot: **Rebase conflict${MERGED_PR_NOTE}** — Builder needs to resolve conflicts with \`$BASE_BRANCH\`. Routed to Builder via \`rebase-conflict\` label." 2>/dev/null || \
      log_warn "Could not post conflict comment on PR #$PR_NUM"
    gh pr edit "$PR_NUM" --repo "$REPO" --add-label "rebase-conflict" --add-label "rework" 2>/dev/null || true
    # Convert to draft so Reviewer/Tester don't pick up an unmergable PR
    gh pr ready "$PR_NUM" --repo "$REPO" --undo 2>/dev/null || true

    CONFLICTS=$(echo "$CONFLICTS" | jq --argjson num "$PR_NUM" --arg branch "$BRANCH_NAME" --arg reason "Rebase conflict" '. + [{number: $num, branch: $branch, reason: $reason}]')
  fi

  # Clean up temp worktree
  if [[ "$CLEANUP_WT" == "true" && -d "$TEMP_WT" ]]; then
    git -C "$HELIX_REPO_ROOT" worktree remove "$TEMP_WT" --force 2>/dev/null || rm -rf "$TEMP_WT"
  fi

done < <(echo "$OPEN_PRS" | jq -c '.[]')

# ── Report results ────────────────────────────────────
REBASED_COUNT=$(echo "$REBASED" | jq 'length')
CONFLICT_COUNT=$(echo "$CONFLICTS" | jq 'length')

log_info "Rebase complete: $REBASED_COUNT succeeded, $CONFLICT_COUNT conflicts"

jq -n \
  --argjson rebased "$REBASED" \
  --argjson conflicts "$CONFLICTS" \
  '{rebased: $rebased, conflicts: $conflicts}'
