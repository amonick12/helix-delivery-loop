#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
for test in "$DIR"/test-*.sh; do
  echo "=== $(basename "$test") ==="
  if bash "$test" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  echo
done
echo "=== $PASS suites passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
