#!/bin/bash
# backfill-pr-specs.sh — Add a "## Technical Spec" section to any open PR
# whose body is missing one. Idempotent: PRs that already have the section
# are skipped. Spec content is recovered from:
#   1. /tmp/helix-artifacts/<card>/spec.md (current Planner artifact)
#   2. git log search for any historic spec.md added under docs/cards or
#      docs/epics/*/cards/* whose path contains the card id.
#
# Usage:
#   ./backfill-pr-specs.sh           # all open PRs
#   ./backfill-pr-specs.sh --pr 234  # one PR
#
# Exit 0 always (per-PR errors are logged but do not fail the script).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

TARGET_PR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) TARGET_PR="$2"; shift 2 ;;
    *)    echo "Usage: backfill-pr-specs.sh [--pr <N>]" >&2; exit 2 ;;
  esac
done

# ── Get list of PRs to process ────────────────────────────
if [[ -n "$TARGET_PR" ]]; then
  PR_LIST="$TARGET_PR"
else
  PR_LIST=$(gh pr list --repo "$REPO" --state open --json number --jq '.[].number' 2>/dev/null)
fi

card_for_pr() {
  local pr=$1 body branch card
  body=$(gh pr view "$pr" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")
  card=$(echo "$body" | grep -oE 'Closes #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [[ -z "$card" ]]; then
    branch=$(gh pr view "$pr" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null || echo "")
    card=$(echo "$branch" | grep -oE '[0-9]+' | head -1 || true)
  fi
  echo "$card"
}

find_spec_for_card() {
  local card=$1

  # 1. Current Planner artifact
  if [[ -f "/tmp/helix-artifacts/$card/spec.md" ]]; then
    cat "/tmp/helix-artifacts/$card/spec.md"
    return 0
  fi

  # 2. Search git history for a committed spec.md that mentions the card.
  # Walk every commit that ever added a spec.md under docs/ and pick the
  # one whose path contains the card id (or the card id appears in the
  # spec body title).
  local commit path
  while IFS= read -r commit; do
    [[ -z "$commit" ]] && continue
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      # Path-based match (most reliable)
      if [[ "$path" == *"/${card}-"* || "$path" == *"/${card}/"* ]]; then
        git show "${commit}:${path}" 2>/dev/null && return 0
      fi
    done < <(git show --name-only --diff-filter=A --pretty=format: "$commit" 2>/dev/null \
              | grep -E '(docs/cards/|docs/epics/.*/cards/|docs/specs/).*spec\.md|docs/specs/.*\.md' || true)
  done < <(git log --all --diff-filter=A --pretty=format:%H -- 'docs/cards/**/spec.md' 'docs/epics/**/cards/**/spec.md' 'docs/specs/*.md' 2>/dev/null)

  return 1
}

embed_spec_in_body() {
  local pr=$1 spec_file=$2 body_file out_file
  body_file="/tmp/backfill-pr${pr}-current.md"
  out_file="/tmp/backfill-pr${pr}-new.md"
  gh pr view "$pr" --repo "$REPO" --json body --jq '.body' > "$body_file" 2>/dev/null

  if grep -q '^## Technical Spec' "$body_file"; then
    echo "PR #$pr: already has Technical Spec section, skipping"
    rm -f "$body_file"
    return 0
  fi

  # Insert spec section right after the Acceptance Criteria block. Fall
  # back to appending at the end if Acceptance Criteria is not present.
  if grep -q '^## Acceptance Criteria' "$body_file"; then
    awk -v specfile="$spec_file" '
      BEGIN { inserted = 0 }
      /^## / && in_ac && !inserted {
        print "## Technical Spec\n\n<details>\n<summary>Spec & implementation plan (recovered from git history)</summary>\n"
        while ((getline line < specfile) > 0) print line
        close(specfile)
        print "\n</details>\n"
        inserted = 1
        in_ac = 0
      }
      /^## Acceptance Criteria/ { in_ac = 1 }
      { print }
      END {
        if (!inserted) {
          print "\n## Technical Spec\n\n<details>\n<summary>Spec & implementation plan (recovered from git history)</summary>\n"
          while ((getline line < specfile) > 0) print line
          close(specfile)
          print "\n</details>"
        }
      }
    ' "$body_file" > "$out_file"
  else
    cp "$body_file" "$out_file"
    {
      printf "\n## Technical Spec\n\n<details>\n<summary>Spec & implementation plan (recovered from git history)</summary>\n\n"
      cat "$spec_file"
      printf "\n\n</details>\n"
    } >> "$out_file"
  fi

  if gh pr edit "$pr" --repo "$REPO" --body-file "$out_file" >/dev/null 2>&1; then
    echo "PR #$pr: spec backfilled"
  else
    echo "PR #$pr: gh pr edit failed" >&2
  fi
  rm -f "$body_file" "$out_file"
}

for pr in $PR_LIST; do
  card=$(card_for_pr "$pr")
  if [[ -z "$card" ]]; then
    echo "PR #$pr: no linked card, skipping"
    continue
  fi

  # Short-circuit: PR already has a spec section, nothing to do.
  if gh pr view "$pr" --repo "$REPO" --json body --jq '.body' 2>/dev/null \
       | grep -q '^## Technical Spec'; then
    echo "PR #$pr: already has Technical Spec section, skipping"
    continue
  fi

  spec_tmp="/tmp/backfill-spec-${card}.md"
  if find_spec_for_card "$card" > "$spec_tmp" 2>/dev/null && [[ -s "$spec_tmp" ]]; then
    embed_spec_in_body "$pr" "$spec_tmp"
  else
    echo "PR #$pr (card #$card): no spec found in artifacts or git history, skipping"
  fi
  rm -f "$spec_tmp"
done
