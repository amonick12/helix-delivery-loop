#!/bin/bash
# security-scan.sh — Deterministic security scan for PR diffs.
# Checks for common iOS/Swift security issues without LLM.
#
# Usage:
#   ./security-scan.sh --worktree <path> [--base autodev]
#
# Returns JSON: {passed: bool, findings: [{severity, file, line, rule, detail}]}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

WORKTREE=""
BASE_BRANCH="autodev"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="$2"; shift 2 ;;
    --base)     BASE_BRANCH="$2"; shift 2 ;;
    -h|--help)  echo "Usage: security-scan.sh --worktree <path> [--base autodev]"; exit 0 ;;
    *)          echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$WORKTREE" ]] && echo "Error: --worktree required" >&2 && exit 1
[[ ! -d "$WORKTREE" ]] && echo "Error: worktree not found: $WORKTREE" >&2 && exit 1

cd "$WORKTREE"

# Get changed Swift files
CHANGED_FILES=$(git diff --name-only "origin/${BASE_BRANCH}...HEAD" -- '*.swift' 2>/dev/null || true)
[[ -z "$CHANGED_FILES" ]] && echo '{"passed":true,"findings":[]}' && exit 0

FINDINGS="[]"

add_finding() {
  local severity="$1" file="$2" line="$3" rule="$4" detail="$5"
  FINDINGS=$(echo "$FINDINGS" | jq --arg s "$severity" --arg f "$file" --argjson l "$line" --arg r "$rule" --arg d "$detail" \
    '. += [{severity: $s, file: $f, line: $l, rule: $r, detail: $d}]')
}

while IFS= read -r file; do
  [[ -z "$file" || ! -f "$file" ]] && continue

  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # 1. Hardcoded secrets/keys
    if echo "$line" | grep -qiE '(api[_-]?key|secret|password|token)\s*[:=]\s*"[^"]{8,}"'; then
      add_finding "P0" "$file" "$line_num" "hardcoded-secret" "Possible hardcoded secret or API key"
    fi

    # 2. Insecure HTTP URLs (not HTTPS)
    if echo "$line" | grep -qE 'http://[^"]' | grep -qvE 'http://localhost|http://127\.0\.0\.1'; then
      add_finding "P1" "$file" "$line_num" "insecure-http" "HTTP URL found — use HTTPS"
    fi

    # 3. UserDefaults for sensitive data
    if echo "$line" | grep -qE 'UserDefaults.*\.(set|string|data).*\b(password|token|secret|key)\b'; then
      add_finding "P1" "$file" "$line_num" "sensitive-userdefaults" "Storing sensitive data in UserDefaults — use Keychain"
    fi

    # 4. Force unwrapping in non-test code
    if [[ "$file" != *"Tests"* ]] && echo "$line" | grep -qE '!\.' | grep -qvE '//|/\*|\bguard\b|\bif\b'; then
      # Only flag if it looks like a force unwrap, not a negation
      if echo "$line" | grep -qE '[a-zA-Z]\!\.'; then
        add_finding "P2" "$file" "$line_num" "force-unwrap" "Force unwrap in production code — consider safe unwrapping"
      fi
    fi

    # 5. Printing sensitive data
    if echo "$line" | grep -qE 'print\(.*\b(password|token|secret|apiKey)\b'; then
      add_finding "P1" "$file" "$line_num" "sensitive-logging" "Logging potentially sensitive data"
    fi

    # 6. Disabled SSL/TLS verification
    if echo "$line" | grep -qiE 'allowsConstrainedNetworkAccess|serverTrustPolicy|disable.*ssl|disable.*tls'; then
      add_finding "P0" "$file" "$line_num" "disabled-ssl" "SSL/TLS verification may be disabled"
    fi

    # 7. SQL injection (raw string interpolation in queries)
    if echo "$line" | grep -qE 'NSPredicate.*format.*\\('; then
      add_finding "P1" "$file" "$line_num" "predicate-injection" "String interpolation in NSPredicate — use %@ arguments"
    fi

  done < "$file"
done <<< "$CHANGED_FILES"

# Result
P0_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "P0")] | length')
P1_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "P1")] | length')
PASSED=true
[[ "$P0_COUNT" -gt 0 || "$P1_COUNT" -gt 0 ]] && PASSED=false

echo "$FINDINGS" | jq --argjson passed "$PASSED" '{passed: $passed, findings: .}'
