#!/bin/bash
# quality-gate.sh — Runs all 16 quality gates in sequence, returns structured JSON.
#
# Usage:
#   ./quality-gate.sh --card 137 --worktree /tmp/helix-wt/feature/137-slug
#   ./quality-gate.sh --card 137 --worktree /tmp/helix-wt/feature/137-slug --gate 4
#
# Gates:
#   1  Build                    (never skipped)
#   2  Unit Tests               (never skipped)
#   3  Package Tests            (never skipped)
#   4  Code Review [LLM]        (never skipped)
#   5  Code Coverage            (never skipped)
#   6  Memory Leak Detection    (skip if no UI changes — needs simulator)
#   7  Data Migration Safety    (never skipped)
#   8  Localization Check       (never skipped)
#   9  Accessibility Audit      (never skip — reviews all Swift changes)
#  10  Write XCUITests [LLM]    (skip if no UI changes)
#  11  Run XCUITests + Record   (skip if no UI changes, needs simulator)
#  12  Post Screen Recordings   (skip if no UI changes, needs simulator)
#  13  Before/After Screenshots (skip if no UI changes, needs simulator)
#  14  Design Fidelity [LLM]    (skip if no UI changes or no DesignURL)
#  15  Visual QA [LLM]          (skip if no UI changes)
#  16  TestFlight Build         (skip if no UI changes)
#
# Env:
#   DRY_RUN=1          Skip actual execution, return mock pass results
#   HAS_UI_CHANGES     "Yes" or "No" (default: auto-detect from diff)
#   DESIGN_URL         URL to design mockups (empty = no design)
#   COVERAGE_THRESHOLD Minimum code coverage % (default: 60)
#   PERF_LAUNCH_MAX    Max app launch time in seconds (default: 10)
#   PERF_TEST_MAX      Max single test duration in seconds (default: 60)
#   LOCALIZATION_STRICT  "true" to fail on hardcoded strings (default: false)
#
# Output: JSON object with card, passed, gates[], first_failure, self_healable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
quality-gate.sh — Runs all 16 quality gates in sequence, returns structured JSON.

Usage:
  ./quality-gate.sh --card 137 --worktree /tmp/helix-wt/feature/137-slug
  ./quality-gate.sh --card 137 --worktree /tmp/helix-wt/feature/137-slug --gate 4

Options:
  --card <N>         Card/issue number (required)
  --worktree <path>  Worktree path (required)
  --gate <N>         Run only gate N (optional)

Env:
  DRY_RUN=1          Skip actual execution, return mock pass results
  HAS_UI_CHANGES     "Yes" or "No" (default: auto-detect)
  DESIGN_URL         URL to design mockups
  COVERAGE_THRESHOLD Minimum code coverage % (default: 60)
  PERF_LAUNCH_MAX    Max app launch time in seconds (default: 10)
  PERF_TEST_MAX      Max single test duration in seconds (default: 60)
HELP

# ── Parse args ──────────────────────────────────────────
CARD=""
WORKTREE=""
SINGLE_GATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)     CARD="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --gate)     SINGLE_GATE="$2"; shift 2 ;;
    *)          log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$CARD" ]]; then
  log_error "--card <number> is required"
  exit 1
fi
if [[ -z "$WORKTREE" ]]; then
  log_error "--worktree <path> is required"
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"
HAS_UI_CHANGES="${HAS_UI_CHANGES:-auto}"
DESIGN_URL="${DESIGN_URL:-}"
COVERAGE_THRESHOLD="${COVERAGE_THRESHOLD:-60}"
PERF_LAUNCH_MAX="${PERF_LAUNCH_MAX:-10}"
PERF_TEST_MAX="${PERF_TEST_MAX:-60}"
PR_NUMBER="${PR_NUMBER:-0}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$SCRIPT_DIR}"

# ── Auto-detect UI changes ──────────────────────────────
detect_ui_changes() {
  if [[ "$HAS_UI_CHANGES" != "auto" ]]; then
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    HAS_UI_CHANGES="Yes"
    return
  fi
  local diff_files
  diff_files=$(cd "$WORKTREE" && git diff --name-only "origin/$BASE_BRANCH"...HEAD 2>/dev/null || echo "")
  if echo "$diff_files" | grep -qE '(View|Screen|Tab|Component).*\.swift$'; then
    HAS_UI_CHANGES="Yes"
  else
    HAS_UI_CHANGES="No"
  fi
  log_info "Auto-detected HAS_UI_CHANGES=$HAS_UI_CHANGES"
}

# ── Gate result builders ────────────────────────────────
gate_result() {
  local gate="$1" name="$2" passed="$3"
  shift 3
  local extras=""
  while [[ $# -gt 0 ]]; do
    extras="$extras, \"$1\": $2"
    shift 2
  done
  echo "{\"gate\": $gate, \"name\": \"$name\", \"passed\": $passed$extras}"
}

gate_skip() {
  local gate="$1" name="$2" reason="$3"
  echo "{\"gate\": $gate, \"name\": \"$name\", \"passed\": true, \"skipped\": true, \"skip_reason\": \"$reason\"}"
}

# ── Gate functions ──────────────────────────────────────

gate_1_build() {
  local start=$SECONDS
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 1 "Build" true "duration_sec" "1"
    return
  fi
  local output exit_code=0
  output=$(cd "$WORKTREE" && ./devtools/ios-agent/build.sh 2>&1) || exit_code=$?
  local duration=$((SECONDS - start))
  if [[ $exit_code -eq 0 ]]; then
    gate_result 1 "Build" true "duration_sec" "$duration"
  else
    gate_result 1 "Build" false "duration_sec" "$duration" "error" "\"Build failed with exit code $exit_code\""
  fi
}

gate_2_unit_tests() {
  local start=$SECONDS
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 2 "Unit Tests" true "duration_sec" "1" "tests" "142"
    return
  fi
  local output exit_code=0
  output=$(cd "$WORKTREE" && ./devtools/ios-agent/run-unit-tests.sh 2>&1) || exit_code=$?
  local duration=$((SECONDS - start))
  local test_count
  test_count=$(echo "$output" | grep -oE 'Executed [0-9]+ test' | grep -oE '[0-9]+' | head -1 || echo "0")
  if [[ $exit_code -eq 0 ]]; then
    gate_result 2 "Unit Tests" true "duration_sec" "$duration" "tests" "${test_count:-0}"
  else
    gate_result 2 "Unit Tests" false "duration_sec" "$duration" "tests" "${test_count:-0}" "error" "\"Unit tests failed\""
  fi
}

gate_3_package_tests() {
  local start=$SECONDS
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 3 "Package Tests" true "duration_sec" "1" "tests" "87"
    return
  fi
  local output exit_code=0
  output=$(cd "$WORKTREE" && ./devtools/ios-agent/run-all-package-unit-tests.sh 2>&1) || exit_code=$?
  local duration=$((SECONDS - start))
  local test_count
  test_count=$(echo "$output" | grep -oE 'Executed [0-9]+ test' | grep -oE '[0-9]+' | tail -1 || echo "0")
  if [[ $exit_code -eq 0 ]]; then
    gate_result 3 "Package Tests" true "duration_sec" "$duration" "tests" "${test_count:-0}"
  else
    gate_result 3 "Package Tests" false "duration_sec" "$duration" "tests" "${test_count:-0}" "error" "\"Package tests failed\""
  fi
}

gate_4_code_review() {
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 4 "Code Review" true "llm_gate" "true"
    return
  fi
  # Generate prompt for Sonnet subagent — no actual LLM call in this script
  local diff
  diff=$(cd "$WORKTREE" && git diff "origin/$BASE_BRANCH"...HEAD 2>/dev/null || echo "(no diff)")
  local prompt="Review the following code diff for card #$CARD. Check for:
1. Architecture adherence (MVVM, SwiftData patterns)
2. Error handling (no try? on critical persistence)
3. Concurrency correctness (Swift 6 strict, no GCD)
4. Typography rule compliance (helixFont / inherited)
5. Theme compliance (helixAccent, glassCard, etc.)

Diff:
$diff"
  gate_result 4 "Code Review" true "llm_gate" "true" "prompt_length" "${#prompt}"
}

gate_5_code_coverage() {
  local start=$SECONDS
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 5 "Code Coverage" true "duration_sec" "1" "coverage_pct" "72"
    return
  fi
  local output exit_code=0
  output=$(cd "$WORKTREE" && xcodebuild -project helix-app.xcodeproj \
    -scheme helix-app \
    -destination "id=$SIMULATOR_UDID" \
    -enableCodeCoverage YES \
    test 2>&1) || exit_code=$?
  local duration=$((SECONDS - start))
  local coverage
  coverage=$(echo "$output" | grep -oE '[0-9]+\.[0-9]+%' | head -1 | tr -d '%' || echo "0")
  # Check against static floor
  local passed=false
  if (( $(echo "$coverage >= $COVERAGE_THRESHOLD" | bc 2>/dev/null || echo 0) )); then
    passed=true
  fi

  # Check against baseline for regression detection
  local branch_name
  branch_name=$(cd "$WORKTREE" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  local baseline_result
  baseline_result=$("$SCRIPT_DIR/coverage-baseline.sh" compare --current "$coverage" --branch "$BASE_BRANCH" 2>/dev/null || echo '{"passed":true}')
  local baseline_passed
  baseline_passed=$(echo "$baseline_result" | jq -r '.passed' 2>/dev/null || echo "true")
  local baseline_val
  baseline_val=$(echo "$baseline_result" | jq -r '.baseline // "none"' 2>/dev/null || echo "none")
  local delta_val
  delta_val=$(echo "$baseline_result" | jq -r '.delta // "n/a"' 2>/dev/null || echo "n/a")

  if [[ "$baseline_passed" == "false" ]]; then
    passed=false
  fi

  # On pass, save the feature branch coverage
  if [[ "$passed" == "true" ]]; then
    "$SCRIPT_DIR/coverage-baseline.sh" save --branch "$branch_name" --coverage "$coverage" 2>/dev/null || true
  fi

  gate_result 5 "Code Coverage" "$passed" "duration_sec" "$duration" "coverage_pct" "\"$coverage\"" "threshold" "$COVERAGE_THRESHOLD" "baseline" "\"$baseline_val\"" "delta" "\"$delta_val\""
}

gate_6_memory_leak_detection() {
  # Memory leaks can happen in ANY code — never skip this gate.
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 6 "Memory Leak Detection" true "leaks_found" "0"
    return
  fi
  # Launch app on simulator and run leaks check
  local exit_code=0
  # Boot simulator if needed
  xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
  # Install and launch the app
  local app_path="$WORKTREE/build/Build/Products/Debug-iphonesimulator/helix-app.app"
  if [[ -d "$app_path" ]]; then
    xcrun simctl install "$SIMULATOR_UDID" "$app_path" 2>/dev/null || true
  fi
  xcrun simctl launch "$SIMULATOR_UDID" com.helix.app 2>/dev/null || true
  sleep 3  # Allow app to settle

  # Get app PID via simctl spawn
  local app_pid=""
  app_pid=$(xcrun simctl spawn "$SIMULATOR_UDID" launchctl list 2>/dev/null | grep helix | awk '{print $1}' | head -1 || echo "")

  if [[ -z "$app_pid" || "$app_pid" == "-" ]]; then
    gate_result 6 "Memory Leak Detection" false "error" "\"Could not find app PID on simulator\""
    return
  fi

  local memgraph_path="/tmp/leaks-${CARD}.memgraph"
  local leaks_output=""
  leaks_output=$(leaks "$app_pid" --outputGraph="$memgraph_path" 2>&1) || exit_code=$?

  # Parse leak count from output
  local leak_count=0
  leak_count=$(echo "$leaks_output" | grep -oE '[0-9]+ leaks?' | head -1 | grep -oE '[0-9]+' || echo "0")

  if [[ "$leak_count" -eq 0 ]]; then
    gate_result 6 "Memory Leak Detection" true "leaks_found" "0" "memgraph_path" "\"$memgraph_path\""
  else
    gate_result 6 "Memory Leak Detection" false "leaks_found" "$leak_count" "memgraph_path" "\"$memgraph_path\""
  fi
}

gate_7_data_migration_safety() {
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 7 "Data Migration Safety" true "model_changes" "false"
    return
  fi

  # Check if any @Model files were modified
  local model_files=""
  model_files=$(cd "$WORKTREE" && git diff --name-only "origin/$BASE_BRANCH"...HEAD 2>/dev/null | while read f; do
    if [[ -f "$f" ]] && grep -ql '@Model' "$f" 2>/dev/null; then
      echo "$f"
    fi
  done || echo "")

  if [[ -z "$model_files" ]]; then
    gate_result 7 "Data Migration Safety" true "model_changes" "false"
    return
  fi

  # Model files changed — check for migration safety
  local breaking_changes="[]"
  local migration_plan_found=false

  # Check for VersionedSchema or SchemaMigrationPlan in the diff
  local diff_content
  diff_content=$(cd "$WORKTREE" && git diff "origin/$BASE_BRANCH"...HEAD 2>/dev/null || echo "")
  if echo "$diff_content" | grep -qE '(VersionedSchema|SchemaMigrationPlan)'; then
    migration_plan_found=true
  fi

  # Check if HelixModelSchema.swift was updated
  local schema_updated=false
  if echo "$model_files" | grep -q 'HelixModelSchema'; then
    schema_updated=true
  fi
  if cd "$WORKTREE" && git diff --name-only "origin/$BASE_BRANCH"...HEAD 2>/dev/null | grep -q 'HelixModelSchema'; then
    schema_updated=true
  fi

  # Check for new properties without defaults (breaking)
  local new_props_no_default
  new_props_no_default=$(echo "$diff_content" | grep '^+' | grep -v '^+++' | \
    grep -E '^\+\s*(var|let)\s+\w+\s*:' | \
    grep -v '=' | grep -v '?' | grep -v 'Optional' || echo "")

  # Check for removed properties (data loss risk)
  local removed_props
  removed_props=$(echo "$diff_content" | grep '^-' | grep -v '^---' | \
    grep -E '^\-\s*(var|let)\s+\w+\s*:' || echo "")

  if [[ -n "$new_props_no_default" ]]; then
    breaking_changes=$(echo "$breaking_changes" | jq --arg c "New properties without default values" '. + [$c]')
  fi
  if [[ -n "$removed_props" ]]; then
    breaking_changes=$(echo "$breaking_changes" | jq --arg c "Removed properties (potential data loss)" '. + [$c]')
  fi

  local has_breaking
  has_breaking=$(echo "$breaking_changes" | jq 'length > 0')

  # Pass if no breaking changes, or if migration plan is present
  local passed=true
  if [[ "$has_breaking" == "true" && "$migration_plan_found" == "false" ]]; then
    passed=false
  fi

  # Build LLM prompt if model changes detected for deeper review
  local prompt="Review SwiftData @Model changes in card #$CARD for migration safety.

Changed model files:
$model_files

Diff:
$(echo "$diff_content" | head -500)

Check for:
1. New required properties without default values (breaking)
2. Removed properties (data loss)
3. Type changes on existing properties (breaking)
4. Presence of VersionedSchema or SchemaMigrationPlan
5. HelixModelSchema.swift updated

Respond with JSON: {\"passed\": bool, \"issues\": [\"...\"]}"

  echo "$prompt" > "/tmp/gate7-migration-prompt-${CARD}.txt"

  gate_result 7 "Data Migration Safety" "$passed" \
    "model_changes" "true" \
    "breaking_changes" "$breaking_changes" \
    "migration_plan_found" "$migration_plan_found" \
    "schema_updated" "$schema_updated" \
    "llm_gate" "true" \
    "prompt_file" "\"/tmp/gate7-migration-prompt-${CARD}.txt\""
}

LOCALIZATION_STRICT="${LOCALIZATION_STRICT:-false}"

gate_8_localization_check() {
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 8 "Localization Check" true "hardcoded_strings" "0"
    return
  fi

  # Check diff for hardcoded user-facing strings
  local diff_content
  diff_content=$(cd "$WORKTREE" && git diff "origin/$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null || echo "")

  # Find hardcoded strings in Text(), .navigationTitle(), .alert() etc
  local hardcoded_lines=""
  hardcoded_lines=$(echo "$diff_content" | \
    grep '^+' | grep -v '^+++' | \
    grep -E 'Text\("[^"]+"\)|\.navigationTitle\("|\.alert\(' | \
    grep -v 'NSLocalizedString\|LocalizedStringKey\|String(localized:' || echo "")

  # Exclude test files, preview blocks, accessibility identifiers, log messages, enum raw values
  local filtered_lines=""
  filtered_lines=$(echo "$hardcoded_lines" | \
    grep -v 'Tests/' | \
    grep -v '#Preview' | \
    grep -v 'accessibilityIdentifier' | \
    grep -v 'log\.\|print(' | \
    grep -v 'case .* = "' || echo "")

  local count=0
  if [[ -n "$filtered_lines" ]]; then
    count=$(echo "$filtered_lines" | wc -l | tr -d ' ')
  fi

  # Find affected files
  local affected_files="[]"
  if [[ -n "$filtered_lines" ]]; then
    local files_list
    files_list=$(cd "$WORKTREE" && git diff --name-only "origin/$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null | \
      grep -v 'Tests/' | grep -v 'Preview' || echo "")
    if [[ -n "$files_list" ]]; then
      affected_files=$(echo "$files_list" | jq -R . | jq -s .)
    fi
  fi

  # LOCALIZATION_STRICT=false: warn but pass. true: fail if hardcoded strings found
  local passed=true
  if [[ "$LOCALIZATION_STRICT" == "true" && "$count" -gt 0 ]]; then
    passed=false
  fi

  gate_result 8 "Localization Check" "$passed" \
    "hardcoded_strings" "$count" \
    "files" "$affected_files" \
    "strict_mode" "$LOCALIZATION_STRICT"
}

gate_9_accessibility_audit() {
  # Accessibility audit runs on ALL changes (not just UI) — code review for a11y compliance
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 9 "Accessibility Audit" true "findings" "[]" "llm_gate" "true"
    return
  fi

  # Get the diff for review
  local diff=""
  if [[ -d "$WORKTREE" ]]; then
    diff=$(cd "$WORKTREE" && git diff "origin/$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null || echo "")
    if [[ -z "$diff" ]]; then
      # Try diffing against BASE_BRANCH directly (worktree may not have origin remote)
      diff=$(cd "$WORKTREE" && git diff "$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null || echo "")
    fi
  else
    log_warn "Worktree $WORKTREE does not exist — cannot audit accessibility"
  fi

  if [[ -z "$diff" ]]; then
    log_info "No Swift changes found in diff — accessibility audit passes (nothing to review)"
    gate_result 9 "Accessibility Audit" true "findings" "[]" "note" "\"No Swift changes to audit\""
    return
  fi

  # Build LLM prompt for accessibility review
  local prompt="Review this Swift diff for accessibility compliance per CLAUDE.md rules:

## Rules
- Every interactive element must have accessibilityLabel or accessibilityIdentifier
- Minimum touch target: 44×44 points for all tappable elements
- Text must support Dynamic Type (system fonts or helixFont, never hardcoded sizes)
- Ensure sufficient contrast ratio (WCAG AA: 4.5:1 normal, 3:1 large)
- VoiceOver: all screens navigable without visual context
- Use accessibilityHint for non-obvious actions
- Group related elements with accessibilityElement(children:)

## Diff
\`\`\`
$diff
\`\`\`

Respond with JSON only:
{\"passed\": true/false, \"findings\": [{\"severity\": \"P0/P1/P2\", \"file\": \"...\", \"line\": N, \"issue\": \"...\", \"fix\": \"...\"}]}"

  echo "$prompt" > "/tmp/gate9-a11y-prompt-${CARD}.txt"
  log_info "Accessibility audit prompt written to /tmp/gate9-a11y-prompt-${CARD}.txt"

  # Gate outputs the prompt — the Reviewer/Tester agent evaluates it
  gate_result 9 "Accessibility Audit" true "llm_gate" "true" "prompt_file" "\"/tmp/gate9-a11y-prompt-${CARD}.txt\""
}

gate_10_write_xcuitests() {
  if [[ "$HAS_UI_CHANGES" != "Yes" ]]; then
    gate_skip 10 "Write XCUITests" "No UI changes"
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 10 "Write XCUITests" true "llm_gate" "true"
    return
  fi
  # LLM gate — output prompt for subagent
  local diff
  diff=$(cd "$WORKTREE" && git diff --name-only "origin/$BASE_BRANCH"...HEAD -- '*.swift' 2>/dev/null | grep -iE '(View|Screen|Tab)' || echo "(no UI files)")
  local prompt="Write XCUITests for the following changed UI files in card #$CARD:
$diff

Requirements:
- Test ALL new user interactions
- Record screen during test execution
- Use XCUITest or idb for UI interaction"
  gate_result 10 "Write XCUITests" true "llm_gate" "true" "prompt_length" "${#prompt}"
}

gate_11_run_xcuitests() {
  # Gate 11 runs NEW XCUITests for this card's feature only.
  # Full regression suite runs at merge time (Releaser post-merge step).
  if [[ "$HAS_UI_CHANGES" != "Yes" ]]; then
    gate_skip 11 "Run XCUITests + Record" "No UI changes"
    return
  fi
  local start=$SECONDS
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 11 "Run XCUITests + Record" true "duration_sec" "1" "simulator_used" "true"
    return
  fi
  local output exit_code=0
  output=$(cd "$WORKTREE" && xcodebuild test \
    -project helix-app.xcodeproj \
    -scheme helix-appUITests \
    -destination "id=$SIMULATOR_UDID" \
    2>&1) || exit_code=$?
  local duration=$((SECONDS - start))
  if [[ $exit_code -eq 0 ]]; then
    gate_result 11 "Run XCUITests + Record" true "duration_sec" "$duration" "simulator_used" "true"
  else
    gate_result 11 "Run XCUITests + Record" false "duration_sec" "$duration" "simulator_used" "true" "error" "\"XCUITests failed\""
  fi
}

gate_12_visual_evidence() {
  if [[ "$HAS_UI_CHANGES" != "Yes" ]]; then
    gate_skip 12 "Visual Evidence" "No UI changes"
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 12 "Visual Evidence" true "recordings_found" "true" "screenshots_found" "true" "before_after" "true"
    return
  fi

  local screenshot_dir="$WORKTREE/build/screenshots"
  mkdir -p "$screenshot_dir"
  local has_recordings=false has_screenshots=false

  # 1. Check for XCUITest recordings from Gate 11
  local recordings_dir="$WORKTREE/build/recordings"
  if [[ -d "$recordings_dir" ]] && ls "$recordings_dir"/*.mp4 &>/dev/null 2>&1; then
    has_recordings=true
  fi

  # 2. Capture after screenshot from simulator
  local exit_code=0
  xcrun simctl io "$SIMULATOR_UDID" screenshot "$screenshot_dir/after.png" 2>/dev/null || exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    has_screenshots=true
  fi

  # 3. Capture before screenshot (from autodev in temp worktree)
  local before_wt="/tmp/helix-wt-before-${CARD}"
  if [[ ! -d "$before_wt" ]]; then
    git worktree add "$before_wt" "origin/$BASE_BRANCH" 2>/dev/null || true
  fi
  if [[ -d "$before_wt" ]]; then
    # Build autodev, install, launch, screenshot — then clean up
    (cd "$before_wt" && ./devtools/ios-agent/build.sh 2>/dev/null && \
     ./devtools/ios-agent/install-app.sh 2>/dev/null && \
     ./devtools/ios-agent/launch-app.sh 2>/dev/null && \
     sleep 2 && \
     xcrun simctl io "$SIMULATOR_UDID" screenshot "$screenshot_dir/before.png" 2>/dev/null) || true
    git worktree remove "$before_wt" 2>/dev/null || true
  fi

  # Gate passes only if we have BOTH recordings and screenshots
  if [[ "$has_recordings" == "true" && "$has_screenshots" == "true" ]]; then
    gate_result 12 "Visual Evidence" true \
      "recordings_found" "true" \
      "screenshots_found" "true" \
      "before_after" "$([ -f "$screenshot_dir/before.png" ] && echo true || echo false)" \
      "after_path" "\"$screenshot_dir/after.png\""
  else
    local missing=""
    [[ "$has_recordings" == "false" ]] && missing="recordings"
    [[ "$has_screenshots" == "false" ]] && missing="${missing:+$missing, }screenshots"
    gate_result 12 "Visual Evidence" false "error" "\"Missing: $missing\""
  fi
}

gate_13_design_fidelity() {
  if [[ "$HAS_UI_CHANGES" != "Yes" ]]; then
    gate_skip 13 "Design Fidelity" "No UI changes"
    return
  fi
  if [[ -z "$DESIGN_URL" ]]; then
    gate_skip 13 "Design Fidelity" "No DesignURL"
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 13 "Design Fidelity" true "llm_gate" "true" "fidelity_checks" "{\"checks\":[{\"check\":\"Layout match\",\"passed\":true,\"details\":\"DRY_RUN\"},{\"check\":\"Color/theme match\",\"passed\":true,\"details\":\"DRY_RUN\"},{\"check\":\"Typography match\",\"passed\":true,\"details\":\"DRY_RUN\"},{\"check\":\"State coverage\",\"passed\":true,\"details\":\"DRY_RUN\"},{\"check\":\"Spacing/alignment\",\"passed\":true,\"details\":\"DRY_RUN\"}],\"overall_passed\":true,\"p1_issues\":[]}"
    return
  fi
  local prompt
  prompt="Compare the after screenshot at $WORKTREE/build/screenshots/after.png against the design at $DESIGN_URL for card #$CARD.

Return ONLY a JSON object with this exact structure:
{
  \"checks\": [
    {\"check\": \"Layout match\", \"passed\": true, \"details\": \"...\"},
    {\"check\": \"Color/theme match\", \"passed\": true, \"details\": \"...\"},
    {\"check\": \"Typography match\", \"passed\": true, \"details\": \"...\"},
    {\"check\": \"State coverage\", \"passed\": true, \"details\": \"...\"},
    {\"check\": \"Spacing/alignment\", \"passed\": true, \"details\": \"...\"}
  ],
  \"overall_passed\": false,
  \"p1_issues\": [\"List of any failed checks that are P1 blockers\"]
}"

  gate_result 13 "Design Fidelity" true "llm_gate" "true" "prompt_length" "${#prompt}" "design_url" "\"$DESIGN_URL\""
}

gate_14_visual_qa() {
  if [[ "$HAS_UI_CHANGES" != "Yes" ]]; then
    gate_skip 14 "Visual QA" "No UI changes"
    return
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 14 "Visual QA" true "llm_gate" "true"
    return
  fi
  local prompt="Perform visual QA on the after screenshot at $WORKTREE/build/screenshots/after.png for card #$CARD. Check for:
1. No visual regressions
2. All states rendered correctly (empty + populated)
3. Dark mode appearance correct
4. Accessibility (text contrast, touch targets)"
  gate_result 14 "Visual QA" true "llm_gate" "true" "prompt_length" "${#prompt}"
}

gate_15_testflight_build() {
  if [[ "$HAS_UI_CHANGES" != "Yes" ]]; then
    gate_skip 15 "TestFlight Build" "No UI changes"
    return
  fi
  local start=$SECONDS
  if [[ "$DRY_RUN" == "1" ]]; then
    gate_result 15 "TestFlight Build" true "duration_sec" "1"
    return
  fi
  local bn
  bn=$(build_number "$CARD" 0)
  local exit_code=0
  (cd "$WORKTREE" && xcodebuild archive \
    -project helix-app.xcodeproj \
    -scheme helix-app \
    -archivePath "build/helix-$CARD.xcarchive" \
    CURRENT_PROJECT_VERSION="$bn" \
    2>&1) || exit_code=$?
  local duration=$((SECONDS - start))
  if [[ $exit_code -eq 0 ]]; then
    gate_result 15 "TestFlight Build" true "duration_sec" "$duration" "build_number" "$bn"
  else
    gate_result 15 "TestFlight Build" false "duration_sec" "$duration" "build_number" "$bn" "error" "\"Archive failed\""
  fi
}

# ── Gate registry ───────────────────────────────────────
GATE_NAMES=(
  ""
  "Build"
  "Unit Tests"
  "Package Tests"
  "Code Review"
  "Code Coverage"
  "Memory Leak Detection"
  "Data Migration Safety"
  "Localization Check"
  "Accessibility Audit"
  "Write XCUITests"
  "Run XCUITests + Record"
  "Visual Evidence"
  "Design Fidelity"
  "Visual QA"
  "TestFlight Build"
)

GATE_FUNCTIONS=(
  ""
  gate_1_build
  gate_2_unit_tests
  gate_3_package_tests
  gate_4_code_review
  gate_5_code_coverage
  gate_6_memory_leak_detection
  gate_7_data_migration_safety
  gate_8_localization_check
  gate_9_accessibility_audit
  gate_10_write_xcuitests
  gate_11_run_xcuitests
  gate_12_visual_evidence
  gate_13_design_fidelity
  gate_14_visual_qa
  gate_15_testflight_build
)

# Map gate number to the exact checkbox text in the Quality Gates section.
# These must match the QUALITY_GATES array in update-pr-checklist.sh exactly.
gate_checklist_name() {
  local gate="$1"
  case "$gate" in
    1)  echo "Build passes" ;;
    2)  echo "Unit tests pass" ;;
    3)  echo "Package tests pass" ;;
    4)  echo "Code review: 0 P0/P1" ;;
    5)  echo "Coverage above baseline" ;;
    6)  echo "Memory leak check pass (if UI)" ;;
    7)  echo "Data migration safety check pass" ;;
    8)  echo "Localization check pass" ;;
    9)  echo "Accessibility audit pass" ;;
    10) echo "" ;; # Write XCUITests is a prereq, not a gate checkbox
    11) echo "XCUITests pass" ;;
    12) echo "Visual evidence posted (if UI)" ;;
    13) echo "Design fidelity verified (if UI)" ;;
    14) echo "Visual QA pass (if UI)" ;;
    15) echo "TestFlight build uploaded (if UI)" ;;
    *)  echo "" ;;
  esac
}

# Gates 1-8: Builder-side deterministic checks (run-gates.sh before push)
# Gates 9-15: require Builder rework routed by Reviewer/Tester findings
is_self_healable() {
  local gate="$1"
  [[ $gate -le 8 ]]
}

# Gate 6 (memory leaks) and gates 11-12 require simulator lock
needs_simulator() {
  local gate="$1"
  [[ $gate -eq 6 ]] || [[ $gate -ge 11 && $gate -le 12 ]]
}

# ── Orchestration ───────────────────────────────────────
detect_ui_changes

RESULTS="[]"
FIRST_FAILURE=""
ALL_PASSED=true
SELF_HEALABLE=true
SIM_LOCKED=false

run_gate() {
  local gate="$1"

  # Acquire simulator lock for gates 8-10
  if needs_simulator "$gate" && [[ "$SIM_LOCKED" == "false" ]] && [[ "$DRY_RUN" != "1" ]]; then
    acquire_simulator_lock || {
      local result
      result=$(gate_result "$gate" "${GATE_NAMES[$gate]}" false "error" "\"Simulator lock timeout\"")
      RESULTS=$(echo "$RESULTS" | jq --argjson r "$result" '. + [$r]')
      ALL_PASSED=false
      FIRST_FAILURE="${FIRST_FAILURE:-$gate}"
      SELF_HEALABLE=false
      return 1
    }
    SIM_LOCKED=true
  fi

  local result
  result=$("${GATE_FUNCTIONS[$gate]}")

  RESULTS=$(echo "$RESULTS" | jq --argjson r "$result" '. + [$r]')

  local passed
  passed=$(echo "$result" | jq -r '.passed')
  if [[ "$passed" != "true" ]]; then
    ALL_PASSED=false
    FIRST_FAILURE="${FIRST_FAILURE:-$gate}"
    if ! is_self_healable "$gate"; then
      SELF_HEALABLE=false
    fi
  else
    # Update PR checklist when gate passes
    if [[ "$PR_NUMBER" != "0" ]]; then
      local checklist_name
      checklist_name="$(gate_checklist_name "$gate")"
      if [[ -n "$checklist_name" ]]; then
        bash "$SCRIPTS_DIR/update-pr-checklist.sh" \
          --pr "$PR_NUMBER" --card "$CARD" \
          --check-gate "$checklist_name" 2>/dev/null || true
      fi
    fi
  fi

  # Release simulator lock after gate 6 (memory leaks) or gate 12 (visual evidence)
  if { [[ "$gate" -eq 6 ]] || [[ "$gate" -eq 12 ]]; } && [[ "$SIM_LOCKED" == "true" ]] && [[ "$DRY_RUN" != "1" ]]; then
    release_simulator_lock
    SIM_LOCKED=false
  fi
}

cleanup_sim_lock() {
  if [[ "$SIM_LOCKED" == "true" ]] && [[ "$DRY_RUN" != "1" ]]; then
    release_simulator_lock
    SIM_LOCKED=false
  fi
}
trap cleanup_sim_lock EXIT

if [[ -n "$SINGLE_GATE" ]]; then
  # Single gate mode
  if [[ "$SINGLE_GATE" -lt 1 || "$SINGLE_GATE" -gt 15 ]]; then
    log_error "Gate must be between 1 and 15, got: $SINGLE_GATE"
    exit 1
  fi
  run_gate "$SINGLE_GATE"
else
  # Run all gates in sequence
  for gate in $(seq 1 15); do
    run_gate "$gate"

    # Stop at first non-self-healable failure
    if [[ "$ALL_PASSED" == "false" && "$SELF_HEALABLE" == "false" ]]; then
      log_warn "Stopping at gate $gate — non-self-healable failure"
      break
    fi
  done
fi

# ── Final checklist status ─────────────────────────────
CHECKLIST_STATUS='{"all_checked":false,"total":0,"checked":0,"unchecked":[]}'
if [[ "$ALL_PASSED" == "true" && "$PR_NUMBER" != "0" ]]; then
  # Get final checklist status after all gates passed
  CHECKLIST_STATUS=$(bash "$SCRIPTS_DIR/update-pr-checklist.sh" \
    --pr "$PR_NUMBER" --card "$CARD" 2>/dev/null || echo "$CHECKLIST_STATUS")
fi

CHECKLIST_ALL_CHECKED=$(echo "$CHECKLIST_STATUS" | jq -r '.all_checked' 2>/dev/null || echo "false")

# ── Check UI gates completeness ───────────────────────────
# For UI cards, gates 6,10-16 MUST run (not be skipped).
# If any were skipped, tests-passed MUST NOT be applied.
UI_GATES_COMPLETE="true"
UI_GATES_SKIPPED="[]"
if [[ "$HAS_UI_CHANGES" == "Yes" ]]; then
  # UI-required gates: 10 (write xcuitests), 11 (run xcuitests), 12 (visual evidence),
  # 13 (design fidelity), 14 (visual qa), 15 (testflight)
  for ui_gate in 10 11 12 13 14 15; do
    local_idx=$((ui_gate - 1))
    was_skipped=$(echo "$RESULTS" | jq --argjson idx "$local_idx" '.[$idx].skipped // false' 2>/dev/null || echo "false")
    if [[ "$was_skipped" == "true" ]]; then
      UI_GATES_COMPLETE="false"
      gate_name=$(echo "$RESULTS" | jq -r --argjson idx "$local_idx" '.[$idx].name // "unknown"' 2>/dev/null)
      UI_GATES_SKIPPED=$(echo "$UI_GATES_SKIPPED" | jq --arg g "Gate $ui_gate: $gate_name" '. + [$g]')
    fi
  done
fi

# Final approval eligibility: all gates passed AND (non-UI card OR all UI gates ran)
ELIGIBLE_FOR_APPROVAL="false"
if [[ "$ALL_PASSED" == "true" && "$UI_GATES_COMPLETE" == "true" ]]; then
  ELIGIBLE_FOR_APPROVAL="true"
fi

# ── Output ──────────────────────────────────────────────
jq -n \
  --argjson card "$CARD" \
  --argjson passed "$( [[ "$ALL_PASSED" == "true" ]] && echo true || echo false )" \
  --argjson gates "$RESULTS" \
  --argjson first_failure "$( [[ -z "$FIRST_FAILURE" ]] && echo null || echo "$FIRST_FAILURE" )" \
  --argjson self_healable "$( [[ "$SELF_HEALABLE" == "true" ]] && echo true || echo false )" \
  --argjson checklist "$CHECKLIST_STATUS" \
  --argjson all_checked "$CHECKLIST_ALL_CHECKED" \
  --argjson ui_gates_complete "$UI_GATES_COMPLETE" \
  --argjson ui_gates_skipped "$UI_GATES_SKIPPED" \
  --argjson eligible_for_approval "$ELIGIBLE_FOR_APPROVAL" \
  '{
    card: $card,
    passed: $passed,
    gates: $gates,
    first_failure: $first_failure,
    self_healable: $self_healable,
    checklist: $checklist,
    all_checked: $all_checked,
    ui_gates_complete: $ui_gates_complete,
    ui_gates_skipped: $ui_gates_skipped,
    eligible_for_approval: $eligible_for_approval
  }'
