#!/bin/bash
# cleanup-epic-mockups.sh — remove an epic's SwiftUI mockups after merge.
#
# Called by `postagent.sh` automatically when Releaser merges the LAST sub-card
# of an epic (verified via `check-epic-completion.sh --epic <N>`). Removes:
#
#   1. The directory helix-app/PreviewHost/Mockups/<epic>-<slug>/
#   2. The single line `panels += Epic<N>Mockups.panels` from
#      helix-app/PreviewHost/Mockups/EpicMockupRegistry.swift
#   3. Commits the cleanup to autodev with a clear message.
#
# Mockup files whose `View` struct is referenced from shipping code (i.e.,
# Builder reused the panel directly) are preserved — both the file AND the
# registry line stay so the panel keeps rendering.
#
# Usage:
#   ./cleanup-epic-mockups.sh --epic <N>
#
# Environment:
#   DRY_RUN=1   Skip git/rm — log what would happen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
cleanup-epic-mockups.sh — remove an epic's mockup files + registry entries.

Usage:
  ./cleanup-epic-mockups.sh --epic <N>

Environment:
  DRY_RUN=1   Skip git/rm — log what would happen.

Reads MOCKUP_DIR and MOCKUP_REGISTRY_FILE from config.sh.
HELP

EPIC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --epic) EPIC="$2"; shift 2 ;;
    *)      log_error "Unknown arg: $1"; exit 1 ;;
  esac
done
[[ -z "$EPIC" ]] && { log_error "--epic required"; exit 1; }

# ── Locate the epic's mockup directory ──────────────────
EPIC_DIR=""
if [[ -d "$MOCKUP_DIR" ]]; then
  EPIC_DIR=$(find "$MOCKUP_DIR" -maxdepth 1 -type d -name "${EPIC}-*" 2>/dev/null | head -1)
fi
if [[ -z "$EPIC_DIR" || ! -d "$EPIC_DIR" ]]; then
  log_warn "No mockup directory matching ${EPIC}-* under $MOCKUP_DIR — nothing to remove on disk"
fi

# ── In-Use Detection ────────────────────────────────────
# A mockup file is "in use" if any of its top-level View struct names is
# referenced from a non-Mockups/ Swift file (e.g., Builder reused the mockup
# view directly in the shipping feature). Such files are kept and their
# registry entries are preserved by leaving them out of the strip block
# rewrite.
IN_USE_FILES=()
mockup_struct_names() {
  local file="$1"
  grep -oE '^\s*(public\s+|internal\s+|fileprivate\s+|private\s+)?struct\s+[A-Z][A-Za-z0-9_]+' "$file" 2>/dev/null \
    | awk '{print $NF}' \
    | sort -u
}

is_referenced_outside_mockups() {
  local name="$1"
  # Search all .swift files in the repo, exclude the Mockups dir itself.
  # Match either the bare name or the enum-qualified form `Epic<id>.<Name>`.
  local pattern="\\b${name}\\b|Epic${EPIC}\\.${name}\\b"
  if grep -RIl --include='*.swift' -E "$pattern" "$HELIX_REPO_ROOT/helix-app" "$HELIX_REPO_ROOT/Packages" 2>/dev/null \
       | grep -v "/PreviewHost/Mockups/" \
       | head -1 \
       | grep -q .; then
    return 0
  fi
  return 1
}

if [[ -n "$EPIC_DIR" && -d "$EPIC_DIR" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    keep=false
    while IFS= read -r struct_name; do
      [[ -z "$struct_name" ]] && continue
      if is_referenced_outside_mockups "$struct_name"; then
        log_info "Keeping $(basename "$f"): struct $struct_name is referenced outside Mockups/"
        keep=true
        break
      fi
    done < <(mockup_struct_names "$f")
    if [[ "$keep" == "true" ]]; then
      IN_USE_FILES+=("$f")
    fi
  done < <(find "$EPIC_DIR" -type f -name '*.swift')
fi

# ── Strip the aggregator line for this epic ─────────────
# Designer registers each epic by adding one line:
#     panels += Epic<id>Mockups.panels
# inside the BEGIN/END block of EpicMockupRegistry.swift. We just delete
# that line. If any panel struct from this epic is still referenced from
# shipping code, the IN_USE_FILES detection above will have left those
# files on disk and we leave the registration line in place too.
strip_registry_block() {
  local epic_token="Epic${EPIC}Mockups"

  if ! grep -qE "panels\s*\+=\s*${epic_token}\.panels" "$MOCKUP_REGISTRY_FILE" 2>/dev/null; then
    log_info "No registration line for ${epic_token} in $(basename "$MOCKUP_REGISTRY_FILE") — nothing to strip"
    return 0
  fi

  if [[ ${#IN_USE_FILES[@]} -gt 0 ]]; then
    log_info "Preserving ${epic_token} registration: ${#IN_USE_FILES[@]} mockup file(s) still referenced from shipping code"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would remove 'panels += ${epic_token}.panels' from $MOCKUP_REGISTRY_FILE"
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  grep -vE "panels\s*\+=\s*${epic_token}\.panels" "$MOCKUP_REGISTRY_FILE" > "$tmp"
  mv "$tmp" "$MOCKUP_REGISTRY_FILE"
  log_info "Removed ${epic_token} registration from $(basename "$MOCKUP_REGISTRY_FILE")"
}

# ── Remove directory (preserving in-use files) ──────────
remove_dir() {
  if [[ -z "$EPIC_DIR" || ! -d "$EPIC_DIR" ]]; then
    return 0
  fi

  # If every file in the dir is in use, leave the dir intact.
  local total
  total=$(find "$EPIC_DIR" -type f -name '*.swift' | wc -l | tr -d ' ')
  if [[ "$total" -eq "${#IN_USE_FILES[@]}" && "$total" -gt 0 ]]; then
    log_info "All $total mockup file(s) in $EPIC_DIR are referenced from shipping code — leaving directory intact"
    return 0
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ ${#IN_USE_FILES[@]} -gt 0 ]]; then
      log_info "[DRY_RUN] Would remove $EPIC_DIR contents except ${#IN_USE_FILES[@]} in-use file(s)"
    else
      log_info "[DRY_RUN] Would rm -rf $EPIC_DIR"
    fi
    return 0
  fi

  if [[ ${#IN_USE_FILES[@]} -eq 0 ]]; then
    rm -rf "$EPIC_DIR"
    log_info "Removed $EPIC_DIR"
    return 0
  fi

  # Selective removal: delete every file not in the in-use set.
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local keep=false
    for kept in "${IN_USE_FILES[@]}"; do
      [[ "$f" == "$kept" ]] && keep=true && break
    done
    if [[ "$keep" == "false" ]]; then
      rm -f "$f"
      log_info "Removed unused mockup $(basename "$f")"
    fi
  done < <(find "$EPIC_DIR" -type f -name '*.swift')
  # If only .gitkeep / empty subdirs remain, prune them but keep the epic dir.
  find "$EPIC_DIR" -type d -empty -not -path "$EPIC_DIR" -delete 2>/dev/null || true
}

# ── Verify build still passes after cleanup ─────────────
verify_build() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would verify build"
    return 0
  fi
  log_info "Verifying helix-app still builds after cleanup"
  if ! bash "$MOCKUP_BUILD_SCRIPT" >/dev/null 2>&1; then
    log_error "Build broke after mockup cleanup — restoring file from git and aborting"
    (cd "$HELIX_REPO_ROOT" && git checkout -- "$MOCKUP_REGISTRY_FILE" 2>/dev/null) || true
    if [[ -n "$EPIC_DIR" ]]; then
      (cd "$HELIX_REPO_ROOT" && git checkout -- "$EPIC_DIR" 2>/dev/null) || true
    fi
    return 1
  fi
}

# ── Autodev write lock ──────────────────────────────────
# Two epic-final merges landing within seconds of each other would race on
# the autodev working tree (postagent fires once per merge, each invocation
# of cleanup-epic-mockups.sh wants to git commit + push). Serialize with an
# mkdir-based lock — same pattern as acquire_simulator_lock in config.sh.
AUTODEV_LOCK="/tmp/helix-autodev-write.lock"

acquire_autodev_lock() {
  local timeout=${1:-180}
  local start=$(date +%s)
  while ! mkdir "$AUTODEV_LOCK" 2>/dev/null; do
    local now=$(date +%s)
    if (( now - start > timeout )); then
      local pid_file="$AUTODEV_LOCK/pid"
      if [[ -f "$pid_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
          log_warn "Stale autodev lock from dead PID $lock_pid — removing"
          rm -rf "$AUTODEV_LOCK"
          continue
        fi
      fi
      log_error "autodev write lock timeout after ${timeout}s"
      return 1
    fi
    sleep 2
  done
  echo $$ > "$AUTODEV_LOCK/pid"
  return 0
}

release_autodev_lock() {
  rm -rf "$AUTODEV_LOCK" 2>/dev/null || true
}

# ── Commit cleanup ──────────────────────────────────────
commit_cleanup() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would commit cleanup to $BASE_BRANCH"
    return 0
  fi

  acquire_autodev_lock || return 1
  trap 'release_autodev_lock' RETURN

  cd "$HELIX_REPO_ROOT"
  # Pull + rebase first so we're on top of any concurrent merges that landed
  # since this cleanup decided to run.
  git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true
  git rebase "origin/$BASE_BRANCH" 2>/dev/null || {
    log_warn "Rebase against origin/$BASE_BRANCH failed; aborting cleanup commit (will retry on next dispatch)"
    git rebase --abort 2>/dev/null || true
    return 1
  }

  if ! git diff --quiet -- "$MOCKUP_REGISTRY_FILE" "$MOCKUP_DIR" 2>/dev/null; then
    git add "$MOCKUP_REGISTRY_FILE" 2>/dev/null || true
    [[ -n "$EPIC_DIR" ]] && git add -A "$MOCKUP_DIR" 2>/dev/null || true
    git commit -m "chore(epic-${EPIC}): remove mockups after merge

Auto-cleanup by Releaser. Mockup files for epic #${EPIC} have served their
purpose (Designer→email→approval→Planner→Builder) and are now redundant
with the shipped feature." 2>&1 | grep -v "^$" >&2 || true
    git push origin "$BASE_BRANCH" 2>&1 | grep -v "^$" >&2 || \
      log_warn "Push failed; commit landed locally but not on origin"
    log_info "Committed + pushed mockup cleanup for epic #${EPIC}"
  else
    log_info "No changes to commit for epic-${EPIC} mockup cleanup"
  fi
}

# ── Main ────────────────────────────────────────────────
log_info "Cleaning up mockups for merged epic #${EPIC}"
strip_registry_block
remove_dir
verify_build || exit 1
commit_cleanup

# ── Prune screenshots release assets for this epic ──────
# Designer uploads as design-<card>-<panel>.png; the epic's sub-cards each
# upload PR screenshots (pr-<num>-*.png/.mov). After merge, the assets are
# no longer reference-required; the GitHub Release has a hard ~1000-asset
# / ~50GB cap. Don't lose track over time.
prune_release_assets() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would delete design-${EPIC}-*.png from screenshots release"
    return 0
  fi
  # Collect design-<epic>-* assets and delete them. gh release delete-asset
  # is asset-name-precise; iterate and delete each match.
  gh release view screenshots --repo "$REPO" --json assets \
    --jq ".assets[] | select(.name | startswith(\"design-${EPIC}-\")) | .name" 2>/dev/null \
    | while IFS= read -r asset; do
      [[ -z "$asset" ]] && continue
      gh release delete-asset screenshots "$asset" --repo "$REPO" --yes 2>/dev/null \
        && log_info "Pruned $asset" \
        || log_warn "Could not prune $asset"
    done

  # Also prune sub-card PR screenshots/recordings now that the epic is shipped.
  # Each sub-card's PR uploads named pr-<N>-*.{png,mov,jpg,jpeg,mp4}.
  local sub_card_prs
  sub_card_prs=$(gh issue list --repo "$REPO" --state closed --search "linked:issue-$EPIC" \
    --json number --jq '.[].number' 2>/dev/null || true)
  for sub_card in $sub_card_prs; do
    local pr_num
    pr_num=$(gh pr list --repo "$REPO" --state all --search "linked:issue-${sub_card}" \
      --json number --limit 1 --jq '.[0].number // empty' 2>/dev/null || true)
    [[ -z "$pr_num" ]] && continue
    gh release view screenshots --repo "$REPO" --json assets \
      --jq ".assets[] | select(.name | startswith(\"pr-${pr_num}-\")) | .name" 2>/dev/null \
      | while IFS= read -r asset; do
        [[ -z "$asset" ]] && continue
        gh release delete-asset screenshots "$asset" --repo "$REPO" --yes 2>/dev/null \
          && log_info "Pruned $asset" \
          || log_warn "Could not prune $asset"
      done
  done
}

prune_release_assets

jq -n --argjson epic "$EPIC" --arg dir "$EPIC_DIR" \
  '{epic:$epic, dir_removed:$dir, status:"cleaned"}'
