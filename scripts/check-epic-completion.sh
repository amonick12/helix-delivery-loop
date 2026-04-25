#!/bin/bash
# check-epic-completion.sh — detect when an epic's last sub-card is ready for
# the TestFlight + email confirmation gate.
#
# An epic is "ready for testflight" when every sub-card is either:
#   (a) Done (already merged), OR
#   (b) the LAST one — has both `code-review-approved` AND `visual-qa-approved`
#       labels but NOT yet `user-approved`, AND not already gated by
#       `epic-testflight-pending`.
#
# Usage:
#   check-epic-completion.sh --epic <N>
#
# Output: JSON
#   {epic, sub_card_numbers, last_pr, last_card, ready_for_testflight}
#
# Exit codes:
#   0  — analysis succeeded (check ready_for_testflight in JSON)
#   1  — usage / missing data error

set -euo pipefail

EPIC=""
REPO="${GH_REPO:-amonick12/helix}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --epic) EPIC="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$EPIC" ]] && { echo "Usage: $0 --epic <N>" >&2; exit 1; }

# Find sub-cards: open or closed issues that reference "epic #<N>" in body
# OR have label `epic-<slug>` matching the epic's slug.
sub_cards_json=$(gh issue list --repo "$REPO" --state all --search "in:body \"epic #$EPIC\"" \
  --json number,state,labels,title --limit 50 \
  --jq "[.[] | select(.number != $EPIC)]")

# If no sub-cards yet, return early.
if [[ -z "$sub_cards_json" || "$sub_cards_json" == "[]" ]]; then
  jq -n --argjson epic "$EPIC" '{epic:$epic, sub_card_numbers:[], last_pr:null, last_card:null, ready_for_testflight:false, reason:"no sub-cards yet"}'
  exit 0
fi

# For each sub-card, find its linked PR and label set.
augmented=$(echo "$sub_cards_json" | jq -c '.[]' | while IFS= read -r card; do
  num=$(jq -r '.number' <<<"$card")
  state=$(jq -r '.state' <<<"$card")
  labels=$(jq -c '[.labels[].name]' <<<"$card")
  pr=$(gh pr list --repo "$REPO" --state all --search "linked:issue-$num" \
    --json number,state,labels --limit 1 --jq '.[0] // null')
  jq -n --argjson card "$card" --argjson pr "$pr" --argjson labels "$labels" \
    '{number:$card.number, issue_state:$card.state, labels:$labels, pr:$pr}'
done | jq -s '.')

# Status per card:
#   merged     — issue closed AND PR merged
#   ready_to_merge — has code-review-approved + visual-qa-approved, not user-approved, not testflight-pending
#   gated      — has epic-testflight-pending
#   in_flight  — neither merged nor ready
classify=$(echo "$augmented" | jq -c '.[] | . + {
  status: (
    if .pr.state == "MERGED" then "merged"
    elif (.labels | index("epic-testflight-pending")) then "gated"
    elif ((.labels | index("code-review-approved")) and (.labels | index("visual-qa-approved")) and ((.labels | index("user-approved")) | not)) then "ready_to_merge"
    else "in_flight" end
  )
}' | jq -s '.')

merged_count=$(echo "$classify" | jq '[.[] | select(.status == "merged")] | length')
ready_count=$(echo "$classify" | jq '[.[] | select(.status == "ready_to_merge")] | length')
gated_count=$(echo "$classify" | jq '[.[] | select(.status == "gated")] | length')
in_flight_count=$(echo "$classify" | jq '[.[] | select(.status == "in_flight")] | length')
total=$(echo "$classify" | jq 'length')

# Ready for TestFlight when:
#   - exactly 1 sub-card is `ready_to_merge`
#   - all OTHER sub-cards are `merged` (no in-flight, no already-gated)
ready_for_testflight=false
last_pr=null
last_card=null
reason="not yet ready"

if [[ "$ready_count" -eq 1 && "$in_flight_count" -eq 0 && "$gated_count" -eq 0 && "$total" -gt 0 ]]; then
  ready_for_testflight=true
  reason="last sub-card has all approvals; ready for TestFlight gate"
  last_card_json=$(echo "$classify" | jq '[.[] | select(.status == "ready_to_merge")][0]')
  last_card=$(echo "$last_card_json" | jq '.number')
  last_pr=$(echo "$last_card_json" | jq '.pr.number // null')
elif [[ "$gated_count" -ge 1 ]]; then
  reason="already gated (epic-testflight-pending on $gated_count card(s))"
elif [[ "$merged_count" -eq "$total" ]]; then
  reason="epic complete — all sub-cards merged"
fi

jq -n \
  --argjson epic "$EPIC" \
  --argjson total "$total" \
  --argjson merged "$merged_count" \
  --argjson ready "$ready_count" \
  --argjson gated "$gated_count" \
  --argjson in_flight "$in_flight_count" \
  --argjson last_pr "$last_pr" \
  --argjson last_card "$last_card" \
  --arg ready_bool "$ready_for_testflight" \
  --arg reason "$reason" \
  --argjson sub_cards "$classify" \
  '{
    epic: $epic,
    total_sub_cards: $total,
    counts: {merged:$merged, ready_to_merge:$ready, gated:$gated, in_flight:$in_flight},
    last_pr: $last_pr,
    last_card: $last_card,
    ready_for_testflight: ($ready_bool == "true"),
    reason: $reason,
    sub_cards: $sub_cards
  }'
