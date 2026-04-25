#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"

PASS=0; FAIL=0
assert() { if [[ "$1" == "$2" ]]; then PASS=$((PASS+1)); else echo "FAIL: $3 — expected '$2', got '$1'"; FAIL=$((FAIL+1)); fi; }

# Use temp files for state and board
export STATE_FILE="/tmp/test-dispatcher-state-$$.json"
export BOARD_OVERRIDE="/tmp/test-dispatcher-board-$$.json"
trap "rm -f $STATE_FILE $BOARD_OVERRIDE" EXIT

# Initialize state
echo '{"cards":{}}' > "$STATE_FILE"

# Helper: create board JSON with cards
make_board() {
  echo "$1" > "$BOARD_OVERRIDE"
}

# Helper: run dispatcher and extract agent field
dispatch_agent() {
  bash "$SCRIPT_DIR/dispatcher.sh" --dry-run 2>/dev/null | jq -r '.agent // "none"'
}
dispatch_card() {
  bash "$SCRIPT_DIR/dispatcher.sh" --dry-run 2>/dev/null | jq -r '.card // "none"'
}
dispatch_json() {
  bash "$SCRIPT_DIR/dispatcher.sh" --dry-run 2>/dev/null
}

# ── Rule 1: In Review + new user comment → Builder ──
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix nav","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":[],"recent_comments":[{"body":"Please fix the padding","author":"amonick12","created":"2026-03-28T20:00:00Z"}],
    "fields":{"Status":"In review","Priority":"P1","OwnerAgent":"Reviewer","PR URL":"https://github.com/amonick12/helix/pull/87"}
  }]
}'
echo '{"cards":{"42":{"last_agent":"reviewer","last_comment_check":"2026-03-28T19:00:00Z"}}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "builder" "Rule 1: In Review + new comment → builder"

# ── Rule 2: In Review + user-approved label → Releaser ──
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix nav","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":["user-approved"],"recent_comments":[],
    "fields":{"Status":"In review","Priority":"P1","OwnerAgent":"Reviewer","PR URL":"https://github.com/amonick12/helix/pull/87"}
  }]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "releaser" "Rule 2: In Review + user-approved → releaser"

# ── Rule 3: In Progress + draft PR with rework label → Builder ──
# Reviewer/Tester converts PR to draft and adds "rework" label when routing back.
# Use a high card_id that won't collide with a real PR via `gh pr list --head`
# (resolve_pr_for_card now falls back to gh queries when the PR URL field is empty).
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":987654,"title":"Synthetic","url":"https://github.com/amonick12/helix/issues/987654",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"In progress","Priority":"P1","OwnerAgent":"Builder"}
  }]
}'
echo '{"cards":{"987654":{"last_agent":"reviewer"}}}' > "$STATE_FILE"
# Without a real PR, rules 3/4a/4b/5 fall through; card has no PR URL so
# it falls through to rule 6 (no Ready cards) → rule 7 (no Backlog) → rule 8 (scout)
RESULT=$(dispatch_agent)
assert "$RESULT" "scout" "Rule 3: In Progress without PR URL falls through to scout"

# ── Rule 4a: In Progress + ready PR + no code-review-approved → Reviewer ──
# Rule 4a checks for a ready (non-draft) PR without code-review-approved label.
# In test mode without real PRs, gh pr view fails → fallback {draft:true} → skips.
# We verify the dispatcher handles this gracefully.
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix nav","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"In progress","Priority":"P1","OwnerAgent":"Builder","PR URL":"https://github.com/amonick12/helix/pull/87"}
  }]
}'
echo '{"cards":{"42":{"last_agent":"builder"}}}' > "$STATE_FILE"
# gh pr view fails in test → fallback defaults draft:true → rules 4a/4b skip
# rule 5 picks up draft PR without rework label → builder
RESULT=$(dispatch_agent)
assert "$RESULT" "builder" "Rule 4a: draft PR fallback → builder (rule 5)"

# ── Rule 4b: Tester dispatched after code-review-approved ──
# Rule 4b requires code-review-approved label + no visual-qa-approved.
# Cannot test with real PR labels in unit test; see integration tests.

# ── Rule 5: In Progress + draft PR (no rework) → Builder ──
# Planner creates draft PR. Builder picks it up.
# In test mode, gh pr view fails → fallback {draft:true, rework:false} → matches rule 5.
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix nav","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"In progress","Priority":"P1","OwnerAgent":"Planner","PR URL":"https://github.com/amonick12/helix/pull/88"}
  }]
}'
echo '{"cards":{"42":{"last_agent":"planner"}}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "builder" "Rule 5: draft PR from planner → builder"

# ── Rule 6: Ready card → Planner (respects WIP) ──
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix nav","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"Ready","Priority":"P1"}
  }]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "planner" "Rule 6: Ready → planner"

# ── Rule 6 WIP limit: 4 In Progress + Ready card → skip planner ──
make_board '{
  "cards": [
    {"item_id":"I1","issue_number":39,"title":"A","url":"u","state":"OPEN","labels":[],"recent_comments":[],"fields":{"Status":"In progress","Priority":"P2","OwnerAgent":"Builder"}},
    {"item_id":"I2","issue_number":40,"title":"B","url":"u","state":"OPEN","labels":[],"recent_comments":[],"fields":{"Status":"In progress","Priority":"P2","OwnerAgent":"Builder"}},
    {"item_id":"I3","issue_number":41,"title":"C","url":"u","state":"OPEN","labels":[],"recent_comments":[],"fields":{"Status":"In progress","Priority":"P2","OwnerAgent":"Builder"}},
    {"item_id":"I4","issue_number":42,"title":"D","url":"u","state":"OPEN","labels":[],"recent_comments":[],"fields":{"Status":"In progress","Priority":"P2","OwnerAgent":"Builder"}},
    {"item_id":"I5","issue_number":43,"title":"E","url":"u","state":"OPEN","labels":[],"recent_comments":[],"fields":{"Status":"Ready","Priority":"P1"}}
  ]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_json)
AGENT=$(echo "$RESULT" | jq -r '.agent // "none"')
# Should skip planner due to WIP (4/4), fall through to rule 7/8
assert_not_planner="true"
if [[ "$AGENT" == "planner" ]]; then assert_not_planner="false"; fi
assert "$assert_not_planner" "true" "Rule 6 WIP: skip planner when 4 In Progress"

# ── Rule 7c: Backlog without HasUIChanges → Designer ──
make_board '{
  "cards": [{
    "item_id":"I1","issue_number":42,"title":"Fix nav","url":"https://github.com/amonick12/helix/issues/42",
    "state":"OPEN","labels":[],"recent_comments":[],
    "fields":{"Status":"Backlog","Priority":"P1"}
  }]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "designer" "Rule 7: Backlog no HasUIChanges → designer"

# ── Rule 8: Empty board → Scout ──
make_board '{"cards": []}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "scout" "Rule 8: empty board → scout"

# ── Priority ordering: P0 before P1 ──
make_board '{
  "cards": [
    {"item_id":"I1","issue_number":50,"title":"P1 card","url":"u","state":"OPEN","labels":[],"recent_comments":[],"fields":{"Status":"Ready","Priority":"P1"}},
    {"item_id":"I2","issue_number":42,"title":"P0 card","url":"u","state":"OPEN","labels":[],"recent_comments":[],"fields":{"Status":"Ready","Priority":"P0"}}
  ]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_card)
assert "$RESULT" "42" "Priority: P0 card #42 picked before P1 #50"

# ── Blocked card skipped ──
make_board '{
  "cards": [
    {"item_id":"I1","issue_number":42,"title":"Blocked","url":"u","state":"OPEN","labels":[],"recent_comments":[],"fields":{"Status":"Ready","Priority":"P0","BlockedReason":"Waiting on #40"}},
    {"item_id":"I2","issue_number":43,"title":"Not blocked","url":"u","state":"OPEN","labels":[],"recent_comments":[],"fields":{"Status":"Ready","Priority":"P1"}}
  ]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_card)
assert "$RESULT" "43" "Blocked: skip #42, pick #43"

# ── Rule 7d: UI card with redesign-needed label → Designer ──
make_board '{
  "cards": [
    {"item_id":"I1","issue_number":182,"title":"Insights v2 epic","url":"u","state":"OPEN","labels":["epic","redesign-needed"],"recent_comments":[],"fields":{"Status":"Backlog","Priority":"P1","HasUIChanges":"Yes"}}
  ]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "designer" "Rule 7d: redesign-needed label → designer"
RESULT=$(dispatch_card)
assert "$RESULT" "182" "Rule 7d: redesign-needed label routes to the labeled card"

# ── Rule 7c: user comment newer than last bot Designer comment → Designer ──
make_board '{
  "cards": [
    {"item_id":"I1","issue_number":183,"title":"Atlas epic","url":"u","state":"OPEN","labels":["epic"],"recent_comments":[
      {"author":"github-actions[bot]","body":"bot: Design Mockups (SwiftUI) — see panels","created_at":"2026-04-20T10:00:00Z"},
      {"author":"amonick12","body":"please tighten the spacing on cards","created_at":"2026-04-21T09:00:00Z"}
    ],"fields":{"Status":"Backlog","Priority":"P1","HasUIChanges":"Yes","DesignURL":"https://github.com/x/releases/download/screenshots/design-183-empty.png"}}
  ]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "designer" "Rule 7c: user comment after Designer post → designer"

# ── Rule 7b clean: epic-approved comment with mockups posted → Planner ──
make_board '{
  "cards": [
    {"item_id":"I1","issue_number":184,"title":"Approved epic","url":"u","state":"OPEN","labels":["epic"],"recent_comments":[
      {"author":"amonick12","body":"approve","created_at":"2026-04-21T12:00:00Z"}
    ],"fields":{"Status":"Backlog","Priority":"P1","HasUIChanges":"Yes","DesignURL":"https://github.com/x/releases/download/screenshots/design-184-empty.png"}}
  ]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "planner" "Rule 7b clean: approve + DesignURL → planner"

# ── Rule 7b premature: epic-approved before mockups → Designer (guard) ──
make_board '{
  "cards": [
    {"item_id":"I1","issue_number":185,"title":"Premature epic","url":"u","state":"OPEN","labels":["epic"],"recent_comments":[
      {"author":"amonick12","body":"approve","created_at":"2026-04-21T12:00:00Z"}
    ],"fields":{"Status":"Backlog","Priority":"P1","HasUIChanges":"Yes"}}
  ]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "designer" "Rule 7b guard: HasUIChanges=Yes + empty DesignURL + approve → designer (not planner)"

# ── Rule 2: epic-final-approved label routes to Releaser ──
make_board '{
  "cards": [
    {"item_id":"I1","issue_number":186,"title":"Final approved","url":"u","state":"OPEN","labels":["epic-final-approved"],"recent_comments":[],"fields":{"Status":"In review","Priority":"P1","PR URL":"https://github.com/x/pull/501"}}
  ]
}'
echo '{"cards":{}}' > "$STATE_FILE"
RESULT=$(dispatch_agent)
assert "$RESULT" "releaser" "Rule 2: epic-final-approved label → releaser"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
