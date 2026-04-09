#!/bin/bash
# hook-guard.sh — Re-entrancy guard and profile gating for hooks.
#
# Usage (wrapper):
#   hook-guard.sh <hook-script> [args...]
#
# Environment:
#   ECC_HOOK_PROFILE=minimal|standard|strict  (default: standard)
#     minimal  — skip all optional hooks (only block-force-push runs)
#     standard — run all hooks normally
#     strict   — run all hooks + extra validation
#   ECC_DISABLED_HOOKS=hook1,hook2  — comma-separated list of script names to skip

set -euo pipefail

HOOK_SCRIPT="${1:-}"
[[ -z "$HOOK_SCRIPT" ]] && exit 0
shift

HOOK_NAME="$(basename "$HOOK_SCRIPT" .sh)"
PROFILE="${ECC_HOOK_PROFILE:-standard}"
DISABLED="${ECC_DISABLED_HOOKS:-}"

# 1. Profile gating — minimal skips everything except safety hooks
if [[ "$PROFILE" == "minimal" ]]; then
  case "$HOOK_NAME" in
    block-force-push-autodev|block-screenshot-write) ;; # always run safety hooks
    *) exit 0 ;; # skip everything else
  esac
fi

# 2. Explicit disable list
if [[ -n "$DISABLED" ]]; then
  IFS=',' read -ra DISABLED_LIST <<< "$DISABLED"
  for d in "${DISABLED_LIST[@]}"; do
    [[ "$d" == "$HOOK_NAME" ]] && exit 0
  done
fi

# 3. Re-entrancy guard — prevent the same hook from running recursively
LOCK_DIR="/tmp/helix-hook-locks"
mkdir -p "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/${HOOK_NAME}.lock"

if [[ -f "$LOCK_FILE" ]]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    # Hook is already running in this process tree — skip
    exit 0
  fi
  # Stale lock — remove
  rm -f "$LOCK_FILE"
fi

# Acquire lock
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# 4. Execute the actual hook
exec bash "$HOOK_SCRIPT" "$@"
