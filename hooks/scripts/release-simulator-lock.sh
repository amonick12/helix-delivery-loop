#!/bin/bash
# Stop hook: release simulator lock when session ends
# Prevents stuck locks if Claude crashes mid-agent

LOCK="/tmp/helix-simulator.lock"

if [[ -d "$LOCK" ]]; then
  pid_file="$LOCK/pid"
  if [[ -f "$pid_file" ]]; then
    lock_pid=$(cat "$pid_file")
    # Only release if the owning process is dead
    if ! kill -0 "$lock_pid" 2>/dev/null; then
      rm -rf "$LOCK"
      echo "[helix] Simulator lock released (dead process $lock_pid)" >&2
    fi
  else
    rm -rf "$LOCK"
    echo "[helix] Simulator lock released (no pid file)" >&2
  fi
fi
