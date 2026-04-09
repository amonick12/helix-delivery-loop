#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0
assert() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else echo "FAIL: $3 — expected '$2', got '$1'"; FAIL=$((FAIL+1)); fi; }
assert_set() { if [[ -n "${!1:-}" ]]; then PASS=$((PASS+1)); else echo "FAIL: $1 is not set"; FAIL=$((FAIL+1)); fi; }

# Project constants
assert_set OWNER
assert_set REPO
assert_set PROJECT_ID
assert_set BASE_BRANCH
assert "$BASE_BRANCH" "autodev" "BASE_BRANCH"

# Board field IDs
assert_set FIELD_ID_STATUS
assert_set FIELD_ID_PRIORITY
assert_set FIELD_ID_OWNER_AGENT
assert_set FIELD_ID_BRANCH
assert_set FIELD_ID_PR_URL
assert_set FIELD_ID_DESIGN_URL
assert_set FIELD_ID_LOOP_COUNT

# Status option IDs
assert_set STATUS_BACKLOG
assert_set STATUS_READY
assert_set STATUS_IN_PROGRESS
assert_set STATUS_IN_REVIEW
assert_set STATUS_DONE

# Model assignments
assert_set MODEL_SCOUT
assert_set MODEL_BUILDER
assert_set MODEL_PLANNER
assert_set MODEL_REVIEWER
assert_set MODEL_TESTER
assert_set MODEL_MAINTAINER
assert_set MODEL_RELEASER

# Cost rates
assert_set COST_INPUT_OPUS
assert_set COST_OUTPUT_OPUS
assert_set COST_INPUT_SONNET
assert_set COST_OUTPUT_SONNET

# Simulator
assert_set SIMULATOR_UDID
assert_set SIMULATOR_LOCK

# Stitch
assert_set STITCH_PROJECT_ID
assert_set STITCH_MCP_URL

# Paths
assert_set REPO_ROOT
assert_set PLUGIN_DIR
assert_set SCRIPTS_DIR
assert_set STATE_FILE
assert_set WORKTREE_BASE
assert_set USAGE_DIR

# build_number function
assert "$(build_number 137 0)" "13700" "build_number 137 0"
assert "$(build_number 137 2)" "13702" "build_number 137 2"
assert "$(build_number 148 0)" "14800" "build_number 148 0"

# Simulator lock functions exist
type acquire_simulator_lock &>/dev/null && PASS=$((PASS+1)) || { echo "FAIL: acquire_simulator_lock not defined"; FAIL=$((FAIL+1)); }
type release_simulator_lock &>/dev/null && PASS=$((PASS+1)) || { echo "FAIL: release_simulator_lock not defined"; FAIL=$((FAIL+1)); }

# WIP limits
assert_set WIP_IN_PROGRESS
assert_set WIP_IN_REVIEW

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
