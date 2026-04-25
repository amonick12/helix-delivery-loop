#!/bin/bash
# push-autodev.sh — Safe wrapper for `git push origin autodev`.
#
# Refuses to push unless the current HEAD has been verified by a recent
# build. The verification record is a file at
#   /tmp/helix-build-verified/<sha>
# that contains the unix timestamp of the verification. The verification
# is considered fresh for AUTODEV_VERIFY_TTL seconds (default 600 = 10 min).
#
# To verify a build:
#   ./push-autodev.sh verify [--worktree <path>]
#     Builds the iOS scheme. On success, writes the verification record
#     for the current HEAD SHA. The TTL starts at write time.
#
# To push:
#   ./push-autodev.sh push [--force-with-lease]
#     Checks for a fresh verification record matching HEAD. If missing,
#     stale, or the SHA does not match, the push is refused.
#
# To bypass (NEVER use without explicit user authorization):
#   AUTODEV_PUSH_BYPASS=1 ./push-autodev.sh push
#
# The bypass is logged for auditability.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

VERIFY_DIR="/tmp/helix-build-verified"
AUTODEV_VERIFY_TTL="${AUTODEV_VERIFY_TTL:-600}"

mkdir -p "$VERIFY_DIR"

cmd="${1:-}"; [[ $# -gt 0 ]] && shift || true

case "$cmd" in
  verify)
    WORKTREE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --worktree) WORKTREE="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -z "$WORKTREE" ]] && WORKTREE="$HELIX_REPO_ROOT"
    SHA=$(git -C "$WORKTREE" rev-parse HEAD)
    log_info "Verifying iOS build at $WORKTREE (HEAD=$SHA)..."
    BUILD_LOG="/tmp/push-autodev-verify-${SHA}.log"
    if (cd "$WORKTREE" && xcodebuild \
        -project helix-app.xcodeproj \
        -scheme helix-app \
        -destination 'id=FAB8420B-A062-4973-812A-910024FA3CE1' \
        build > "$BUILD_LOG" 2>&1); then
      date +%s > "$VERIFY_DIR/$SHA"
      log_info "Build verified for $SHA. Push will be allowed for the next ${AUTODEV_VERIFY_TTL}s."
      exit 0
    else
      log_error "Build FAILED. Verification record NOT written. See $BUILD_LOG"
      exit 1
    fi
    ;;

  push)
    FORCE_FLAG=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --force-with-lease) FORCE_FLAG="--force-with-lease"; shift ;;
        *) shift ;;
      esac
    done

    SHA=$(git rev-parse HEAD)

    if [[ "${AUTODEV_PUSH_BYPASS:-0}" == "1" ]]; then
      log_warn "AUTODEV_PUSH_BYPASS=1 — pushing without verification. AUDIT: bypass used at $(date) by $(whoami) for SHA $SHA"
      git push origin autodev $FORCE_FLAG
      exit $?
    fi

    if [[ ! -f "$VERIFY_DIR/$SHA" ]]; then
      log_error "REFUSED: no build verification record for HEAD=$SHA"
      log_error "Run: $0 verify --worktree $(pwd)"
      log_error "Or set AUTODEV_PUSH_BYPASS=1 to override (use sparingly, audited)"
      exit 1
    fi

    VERIFIED_AT=$(cat "$VERIFY_DIR/$SHA")
    NOW=$(date +%s)
    AGE=$(( NOW - VERIFIED_AT ))
    if [[ "$AGE" -gt "$AUTODEV_VERIFY_TTL" ]]; then
      log_error "REFUSED: verification record for $SHA is stale (${AGE}s old, TTL ${AUTODEV_VERIFY_TTL}s)"
      log_error "Run: $0 verify --worktree $(pwd)"
      exit 1
    fi

    log_info "Verification ok (${AGE}s old, SHA $SHA). Pushing to autodev..."
    git push origin autodev $FORCE_FLAG
    exit $?
    ;;

  *)
    cat <<EOF >&2
Usage:
  $0 verify [--worktree <path>]
  $0 push [--force-with-lease]

Safe wrapper for pushing to autodev. Refuses push unless the current HEAD
has been built with the iOS simulator destination in the last ${AUTODEV_VERIFY_TTL} seconds.
EOF
    exit 2
    ;;
esac
