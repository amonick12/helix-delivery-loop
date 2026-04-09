#!/bin/bash
# generate-design.sh — Stitch REST API wrapper for mockup generation.
#
# Usage:
#   ./generate-design.sh --issue 148 --prompt "Insights tab with active themes..."
#   ./generate-design.sh --issue 148 --from-card
#   ./generate-design.sh --issue 148 --base-screen insights-tab
#   ./generate-design.sh --batch 146,147,148
#
# Environment:
#   DRY_RUN=1  — skip API calls and gh commands, just log what would happen
#
# Requires: gh CLI, gcloud CLI, jq, curl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
generate-design.sh — Stitch REST API wrapper for mockup generation.

Usage:
  ./generate-design.sh --issue 148 --prompt "Insights tab with active themes..."
  ./generate-design.sh --issue 148 --from-card
  ./generate-design.sh --issue 148 --base-screen insights-tab
  ./generate-design.sh --batch 146,147,148

Options:
  --issue         Issue number to generate mockup for
  --prompt        Text prompt for screen generation
  --from-card     Parse acceptance criteria from issue body for prompt
  --base-screen   Canonical screen name to edit (e.g. insights-tab, journal-detail)
  --batch         Comma-separated issue numbers to process in batch

Environment:
  DRY_RUN=1     Skip API calls and gh commands, just log what would happen

Requires: gh CLI, gcloud CLI, jq, curl
HELP

# ── Token Management ────────────────────────────────────
get_stitch_token() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "dry-run-token"
    return 0
  fi
  if ! ~/google-cloud-sdk/bin/gcloud auth print-access-token &>/dev/null; then
    log_error "gcloud not authenticated. Run: ~/google-cloud-sdk/bin/gcloud auth login"
    return 1
  fi
  ~/google-cloud-sdk/bin/gcloud auth print-access-token
}

# ── API Wrapper with Retry ──────────────────────────────
stitch_api_call() {
  local payload="$1"
  local max_retries=3
  local delay=1

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would POST to $STITCH_MCP_URL"
    log_info "[DRY_RUN] Payload: $(echo "$payload" | jq -c . 2>/dev/null || echo "$payload")"
    echo '{"result":{"content":[{"text":"{\"outputComponents\":[{\"design\":{\"screens\":[{\"screenshot\":{\"downloadUrl\":\"https://example.com/dry-run-mockup.png\"}}]}}]}"}]}}'
    return 0
  fi

  local TOKEN
  TOKEN=$(get_stitch_token) || return 1

  local attempt=0
  while (( attempt < max_retries )); do
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H "x-goog-user-project: $GCP_PROJECT" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$STITCH_MCP_URL" 2>&1)

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" =~ ^2 ]]; then
      echo "$body"
      return 0
    fi

    attempt=$((attempt + 1))
    if (( attempt < max_retries )); then
      log_warn "Stitch API returned $http_code, retrying in ${delay}s (attempt $attempt/$max_retries)"
      sleep "$delay"
      delay=$((delay * 2))
      # Refresh token on auth failures
      if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        TOKEN=$(get_stitch_token) || return 1
      fi
    else
      log_error "Stitch API failed after $max_retries attempts (last status: $http_code)"
      log_error "Response: $body"
      return 1
    fi
  done
}

# ── Screen ID Resolver ──────────────────────────────────
resolve_screen_id() {
  local screen_name="$1"
  local var_name="STITCH_SCREEN_$(echo "$screen_name" | tr '[:lower:]-' '[:upper:]_')"
  local screen_id="${!var_name:-}"
  if [[ -z "$screen_id" ]]; then
    log_warn "No canonical screen ID for '$screen_name' (var $var_name not set in config.sh)"
    return 1
  fi
  echo "$screen_id"
}

# ── Generate Screen from Text ───────────────────────────
generate_screen_from_text() {
  local prompt="$1"
  local payload
  payload=$(jq -n \
    --arg method "tools/call" \
    --arg name "generate_screen_from_text" \
    --arg project_id "$STITCH_PROJECT_ID" \
    --arg text "$prompt" \
    '{
      jsonrpc: "2.0",
      id: 1,
      method: $method,
      params: {
        name: $name,
        arguments: {
          projectId: $project_id,
          text: $text
        }
      }
    }')

  stitch_api_call "$payload"
}

# ── Edit Existing Screen ────────────────────────────────
edit_screen() {
  local screen_id="$1"
  local prompt="$2"
  local payload
  payload=$(jq -n \
    --arg method "tools/call" \
    --arg name "edit_screens" \
    --arg project_id "$STITCH_PROJECT_ID" \
    --arg screen_id "$screen_id" \
    --arg text "$prompt" \
    '{
      jsonrpc: "2.0",
      id: 1,
      method: $method,
      params: {
        name: $name,
        arguments: {
          projectId: $project_id,
          screenIds: [$screen_id],
          text: $text
        }
      }
    }')

  stitch_api_call "$payload"
}

# ── Response Parsing ────────────────────────────────────
extract_download_urls() {
  local response="$1"
  # Parse nested JSON: result.content[].text contains JSON string with outputComponents
  echo "$response" | jq -r '
    .result.content[]?.text // empty
  ' 2>/dev/null | jq -r '
    .outputComponents[]?.design?.screens[]?.screenshot?.downloadUrl // empty
  ' 2>/dev/null | grep -v '^$' || true
}

# ── Image Download ──────────────────────────────────────
download_mockup() {
  local url="$1"
  local issue="$2"
  local slug="${3:-mockup}"
  local output="/tmp/mockup-${issue}-${slug}.png"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would download $url -> $output"
    echo "$output"
    return 0
  fi

  curl -sL -o "$output" "$url"
  if [[ -f "$output" && -s "$output" ]]; then
    log_info "Downloaded mockup to $output"
    echo "$output"
  else
    log_error "Failed to download mockup from $url"
    rm -f "$output"
    return 1
  fi
}

# ── Issue Posting ───────────────────────────────────────
post_mockup_to_issue() {
  local issue="$1"
  local image_path="$2"
  local label="${3:-Mockup}"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would post mockup comment to issue #$issue"
    log_info "[DRY_RUN] Image: $image_path"
    return 0
  fi

  # Upload image and post comment
  local comment_body="## $label\n\n![mockup]($image_path)"
  gh issue comment "$issue" --repo "$REPO" --body "$(echo -e "$comment_body")"
  log_info "Posted mockup comment to issue #$issue"
}

# ── Design URL Field Update ─────────────────────────────
set_design_url() {
  local issue="$1"
  local url="$2"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[DRY_RUN] Would set DesignURL=$url on issue #$issue"
    return 0
  fi

  "$SCRIPT_DIR/set-field.sh" --issue "$issue" --field "DesignURL" --value "$url" 2>/dev/null || \
    log_warn "Could not set DesignURL on issue #$issue"
}

# ── Design Completeness Check ───────────────────────────
check_design_completeness() {
  local issue="$1"
  local issue_body="$2"
  local mockup_paths="${3:-}"   # space-separated local file paths of downloaded mockups
  local post_table="${4:-true}"

  # Extract checklist items (acceptance criteria)
  local all_criteria
  all_criteria=$(echo "$issue_body" | grep -E '^\s*-\s*\[[ x]\]' | sed 's/^\s*-\s*\[[ x]\]\s*//' || true)

  if [[ -z "$all_criteria" ]]; then
    log_info "No checklist criteria found in issue #$issue body"
    echo '{"complete":true,"visual_total":0,"visual_covered":0,"uncovered":[],"vision_prompt":""}'
    return 0
  fi

  # Classify criteria as visual or non-visual
  local VISUAL_PATTERN='(view|layout|screen|tab|UI|display|show|render|design|button|icon|animation|color|theme|card|list|grid|modal|sheet|nav|header|footer|image|text style|font|spacing|padding|margin|empty state|populated|scroll|tap|swipe)'
  local visual_criteria non_visual_criteria
  visual_criteria=$(echo "$all_criteria" | grep -iE "$VISUAL_PATTERN" || true)
  non_visual_criteria=$(echo "$all_criteria" | grep -viE "$VISUAL_PATTERN" || true)

  local visual_total=0
  if [[ -n "$visual_criteria" ]]; then
    visual_total=$(echo "$visual_criteria" | grep -c . || echo 0)
  fi

  if [[ "$visual_total" -eq 0 ]]; then
    echo '{"complete":true,"visual_total":0,"visual_covered":0,"uncovered":[],"vision_prompt":""}'
    return 0
  fi

  # Build a vision verification prompt for the Designer agent to evaluate.
  # The agent (an LLM with vision) reads each mockup image and checks each criterion.
  # This replaces the old keyword-matching approach with actual image analysis.
  local numbered_criteria=""
  local idx=1
  while IFS= read -r criterion; do
    [[ -z "$criterion" ]] && continue
    numbered_criteria+="$idx. $criterion"$'\n'
    idx=$((idx + 1))
  done <<< "$visual_criteria"

  local mockup_file_list=""
  for f in $mockup_paths; do
    [[ -f "$f" ]] && mockup_file_list+="- $f"$'\n'
  done

  local vision_prompt="## Design Completeness Verification

You are verifying that the generated mockups cover ALL visual acceptance criteria for card #${issue}.

### Mockup Images
Read each mockup image file below using the Read tool:
${mockup_file_list}

### Visual Acceptance Criteria
${numbered_criteria}

### Instructions
For EACH visual criterion above:
1. Look at ALL mockup images
2. Determine if the criterion is VISIBLY represented in at least one mockup
3. A criterion is covered ONLY if you can see the specific UI element, state, or layout it describes

### Required Output
Respond with EXACTLY this JSON (no markdown, no explanation):
{
  \"criteria\": [
    {\"criterion\": \"<text>\", \"covered\": true/false, \"mockup\": \"<which mockup or MISSING>\", \"reason\": \"<what you see or don't see>\"}
  ]
}

Be strict. If a criterion mentions an empty state and no mockup shows an empty state, mark it as NOT covered even if the populated state is shown."

  # In DRY_RUN mode or when no mockup files exist, output the prompt for the agent
  # The AGENT evaluates this prompt using vision, then we parse its JSON response
  local result_json
  if [[ "${DRY_RUN:-0}" == "1" || -z "$mockup_file_list" ]]; then
    # Can't do vision analysis without images or in dry run — fall back to prompt output
    log_info "[DRY_RUN] Vision completeness prompt generated for issue #$issue"
    local uncovered_json="[]"
    while IFS= read -r criterion; do
      [[ -z "$criterion" ]] && continue
      uncovered_json=$(echo "$uncovered_json" | jq --arg c "$criterion" '. + [$c]')
    done <<< "$visual_criteria"
    jq -n \
      --argjson visual_total "$visual_total" \
      --argjson uncovered "$uncovered_json" \
      --arg vision_prompt "$vision_prompt" \
      '{complete: false, visual_total: $visual_total, visual_covered: 0, uncovered: $uncovered, vision_prompt: $vision_prompt}'
    return 0
  fi

  # Output the vision prompt — the Designer agent evaluates it and writes
  # the result to a temp file that we parse
  local result_file="/tmp/design-completeness-${issue}-$$.json"
  echo "$vision_prompt" > "/tmp/design-completeness-prompt-${issue}.txt"

  # The vision_prompt is returned for the agent to evaluate.
  # After evaluation, the agent writes JSON to $result_file.
  # If $result_file doesn't exist yet, output the prompt and mark incomplete.
  if [[ -f "$result_file" ]]; then
    # Parse agent's vision analysis result
    local visual_covered=0
    local uncovered_json="[]"
    local table="## Design Coverage\n\n"
    table+="| # | Criterion | Covered | Mockup | Reason |\n"
    table+="|---|-----------|---------|--------|--------|\n"

    local criteria_count
    criteria_count=$(jq '.criteria | length' "$result_file" 2>/dev/null || echo 0)

    for ((i=0; i<criteria_count; i++)); do
      local c_text c_covered c_mockup c_reason
      c_text=$(jq -r ".criteria[$i].criterion" "$result_file")
      c_covered=$(jq -r ".criteria[$i].covered" "$result_file")
      c_mockup=$(jq -r ".criteria[$i].mockup" "$result_file")
      c_reason=$(jq -r ".criteria[$i].reason" "$result_file")

      if [[ "$c_covered" == "true" ]]; then
        visual_covered=$((visual_covered + 1))
        table+="| $((i+1)) | $c_text | Yes | $c_mockup | $c_reason |\n"
      else
        uncovered_json=$(echo "$uncovered_json" | jq --arg c "$c_text" '. + [$c]')
        table+="| $((i+1)) | $c_text | **No** | $c_mockup | $c_reason |\n"
      fi
    done

    # Add non-visual criteria
    if [[ -n "$non_visual_criteria" ]]; then
      while IFS= read -r criterion; do
        [[ -z "$criterion" ]] && continue
        table+="| — | $criterion | N/A | — | Non-visual |\n"
      done <<< "$non_visual_criteria"
    fi

    local is_complete="false"
    [[ "$visual_covered" -eq "$visual_total" ]] && is_complete="true"

    if [[ "$is_complete" == "true" ]]; then
      table+="\n**Status: 100% visual coverage (vision-verified)**"
    else
      table+="\n**Status: ${visual_covered}/${visual_total} visual criteria covered (vision-verified)**"
    fi

    if [[ "$post_table" == "true" ]]; then
      if [[ "${DRY_RUN:-0}" != "1" ]]; then
        gh issue comment "$issue" --repo "$REPO" --body "$(echo -e "$table")"
      fi
    fi

    jq -n \
      --argjson complete "$is_complete" \
      --argjson visual_total "$visual_total" \
      --argjson visual_covered "$visual_covered" \
      --argjson uncovered "$uncovered_json" \
      '{complete: $complete, visual_total: $visual_total, visual_covered: $visual_covered, uncovered: $uncovered, vision_prompt: ""}'
    rm -f "$result_file"
  else
    # No result file yet — output prompt for agent to evaluate
    jq -n \
      --argjson visual_total "$visual_total" \
      --arg vision_prompt "$vision_prompt" \
      --arg result_file "$result_file" \
      '{complete: false, visual_total: $visual_total, visual_covered: 0, uncovered: [], vision_prompt: $vision_prompt, result_file: $result_file}'
  fi
}

# ── From-Card: Parse Issue Body for Prompt ──────────────
build_prompt_from_card() {
  local issue="$1"
  local issue_body
  issue_body=$(gh issue view "$issue" --repo "$REPO" --json body -q '.body' 2>/dev/null || echo "")

  if [[ -z "$issue_body" ]]; then
    log_error "Could not fetch issue #$issue body"
    return 1
  fi

  local title
  title=$(gh issue view "$issue" --repo "$REPO" --json title -q '.title' 2>/dev/null || echo "Issue #$issue")

  # Extract acceptance criteria and description for prompt
  local criteria
  criteria=$(echo "$issue_body" | grep -E '^\s*-\s*\[[ x]\]' | sed 's/^\s*-\s*\[[ x]\]\s*//' | head -10 || true)

  local prompt="Create a mockup for: $title"
  if [[ -n "$criteria" ]]; then
    prompt="$prompt. Requirements: $(echo "$criteria" | tr '\n' '; ')"
  fi

  echo "$prompt"
  # Store the body for completeness check
  echo "$issue_body" > "/tmp/issue-body-${issue}.txt"
}

# ── Process Single Issue ────────────────────────────────
process_issue() {
  local issue="$1"
  local prompt="${2:-}"
  local from_card="${3:-false}"
  local base_screen="${4:-}"

  log_info "Processing issue #$issue"

  # Build prompt from card if --from-card
  local issue_body=""
  if [[ "$from_card" == "true" ]]; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      prompt="[DRY_RUN] Would build prompt from issue #$issue acceptance criteria"
      log_info "$prompt"
    else
      prompt=$(build_prompt_from_card "$issue")
      issue_body=$(cat "/tmp/issue-body-${issue}.txt" 2>/dev/null || echo "")
      rm -f "/tmp/issue-body-${issue}.txt"
    fi
  fi

  if [[ -z "$prompt" ]]; then
    log_error "No prompt provided for issue #$issue. Use --prompt or --from-card."
    return 1
  fi

  # Generate or edit screen
  local response
  if [[ -n "$base_screen" ]]; then
    local screen_id
    screen_id=$(resolve_screen_id "$base_screen") || {
      log_warn "Falling back to text generation (no screen ID for '$base_screen')"
      response=$(generate_screen_from_text "$prompt")
    }
    if [[ -n "${screen_id:-}" ]]; then
      log_info "Editing canonical screen '$base_screen' ($screen_id)"
      response=$(edit_screen "$screen_id" "$prompt")
    fi
  else
    log_info "Generating screen from text prompt"
    response=$(generate_screen_from_text "$prompt")
  fi

  if [[ -z "${response:-}" ]]; then
    log_error "No response from Stitch API for issue #$issue"
    return 1
  fi

  # Extract and download mockups
  local urls
  urls=$(extract_download_urls "$response")

  if [[ -z "$urls" ]]; then
    log_warn "No mockup URLs found in Stitch response for issue #$issue"
    return 1
  fi

  local slug_index=0
  local downloaded_files=""
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    local slug
    if [[ -n "$base_screen" ]]; then
      slug="${base_screen}-${slug_index}"
    else
      slug="gen-${slug_index}"
    fi
    local file
    file=$(download_mockup "$url" "$issue" "$slug")
    downloaded_files="$downloaded_files $file"
    slug_index=$((slug_index + 1))
  done <<< "$urls"

  # Post to issue
  for file in $downloaded_files; do
    post_mockup_to_issue "$issue" "$file"
  done

  # Set DesignURL field
  local first_url
  first_url=$(echo "$urls" | head -1)
  set_design_url "$issue" "$first_url"

  # Design completeness loop (only with --from-card)
  if [[ "$from_card" == "true" && -n "$issue_body" ]]; then
    local all_mockup_descriptions="$prompt"  # initial prompt describes what we generated
    local iteration=1
    local max_iterations=3

    while [[ $iteration -le $max_iterations ]]; do
      log_info "Completeness check iteration $iteration/$max_iterations for issue #$issue"

      # Check completeness (don't post table on intermediate iterations)
      local post_flag="false"
      [[ $iteration -eq $max_iterations ]] && post_flag="true"

      local result
      result=$(check_design_completeness "$issue" "$issue_body" "$all_mockup_descriptions" "$post_flag")

      local is_complete
      is_complete=$(echo "$result" | jq -r '.complete')

      if [[ "$is_complete" == "true" ]]; then
        log_info "Design completeness: 100% visual coverage for issue #$issue"
        # Post final coverage table
        if [[ "$post_flag" == "false" ]]; then
          check_design_completeness "$issue" "$issue_body" "$all_mockup_descriptions" "true" > /dev/null
        fi
        break
      fi

      # Get uncovered criteria and generate targeted mockups
      local uncovered
      uncovered=$(echo "$result" | jq -r '.uncovered[]')

      if [[ -z "$uncovered" ]]; then
        break
      fi

      log_info "Uncovered criteria found, generating targeted mockups..."
      while IFS= read -r criterion; do
        [[ -z "$criterion" ]] && continue
        local targeted_prompt="Create a mockup specifically showing: $criterion"

        if [[ "${DRY_RUN:-0}" == "1" ]]; then
          log_info "[DRY_RUN] Would generate targeted mockup for: $criterion"
          all_mockup_descriptions="$all_mockup_descriptions, $criterion"
        else
          local targeted_response
          targeted_response=$(generate_screen_from_text "$targeted_prompt") || continue
          local targeted_urls
          targeted_urls=$(extract_download_urls "$targeted_response") || continue

          while IFS= read -r turl; do
            [[ -z "$turl" ]] && continue
            local tfile
            tfile=$(download_mockup "$turl" "$issue" "gap-${iteration}-${slug_index}")
            post_mockup_to_issue "$issue" "$tfile"
            slug_index=$((slug_index + 1))
          done <<< "$targeted_urls"

          all_mockup_descriptions="$all_mockup_descriptions, $criterion"
        fi
      done <<< "$uncovered"

      iteration=$((iteration + 1))
    done

    # Final: if still incomplete after max iterations, post table with gaps
    if [[ $iteration -gt $max_iterations ]]; then
      log_warn "Design completeness: still has gaps after $max_iterations iterations for issue #$issue"
      check_design_completeness "$issue" "$issue_body" "$all_mockup_descriptions" "true" > /dev/null
    fi
  fi

  log_info "Completed mockup generation for issue #$issue"
}

# ── Argument Parsing ────────────────────────────────────
ISSUE=""
PROMPT=""
FROM_CARD="false"
BASE_SCREEN=""
BATCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)        ISSUE="$2"; shift 2 ;;
    --prompt)       PROMPT="$2"; shift 2 ;;
    --from-card)    FROM_CARD="true"; shift ;;
    --base-screen)  BASE_SCREEN="$2"; shift 2 ;;
    --batch)        BATCH="$2"; shift 2 ;;
    *)              log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Batch Mode ──────────────────────────────────────────
if [[ -n "$BATCH" ]]; then
  log_info "Batch mode: processing issues $BATCH"
  IFS=',' read -ra ISSUE_LIST <<< "$BATCH"
  for issue_num in "${ISSUE_LIST[@]}"; do
    issue_num=$(echo "$issue_num" | tr -d ' ')
    process_issue "$issue_num" "$PROMPT" "true" "$BASE_SCREEN" || \
      log_warn "Failed to process issue #$issue_num, continuing batch"
  done
  log_info "Batch complete"
  exit 0
fi

# ── Single Issue Mode ───────────────────────────────────
if [[ -z "$ISSUE" ]]; then
  log_error "--issue or --batch is required"
  exit 1
fi

process_issue "$ISSUE" "$PROMPT" "$FROM_CARD" "$BASE_SCREEN"
