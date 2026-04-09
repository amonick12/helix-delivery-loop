#!/bin/bash
# stitch-api.sh — Reusable wrapper for Stitch REST API (mockup generation).
#
# Commands:
#   stitch-api.sh generate --prompt "..." [--device MOBILE|DESKTOP]
#   stitch-api.sh apply-design-system --instance-id ID --screen-id ID
#   stitch-api.sh status
#
# Outputs JSON with screen_id, instance_id, screenshot_url on success.
# Handles token refresh, timeouts, and error reporting.
#
# Requires: gcloud CLI authenticated, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
stitch-api.sh — Stitch REST API wrapper for mockup generation.

Commands:
  generate --prompt "..."  Generate a screen from text prompt
  apply-design-system      Apply Helix Dark design system to a screen
  status                   Check Stitch API availability

Options:
  --prompt "..."          Text prompt for screen generation
  --device MOBILE|DESKTOP Device type (default: MOBILE)
  --instance-id ID        Screen instance ID (for apply-design-system)
  --screen-id ID          Screen ID (for apply-design-system)
  --model GEMINI_3_1_PRO  Stitch model (default: GEMINI_3_1_PRO)

Requires: gcloud CLI authenticated
HELP

# ── Token Management ──────────────────────────────────────
TOKEN_CACHE="/tmp/helix-stitch-token"
TOKEN_TTL=3000  # 50 minutes (tokens last 60)

get_token() {
  # Use cached token if fresh
  if [[ -f "$TOKEN_CACHE" ]]; then
    local cache_age
    cache_age=$(( $(date +%s) - $(stat -f %m "$TOKEN_CACHE" 2>/dev/null || echo 0) ))
    if [[ $cache_age -lt $TOKEN_TTL ]]; then
      cat "$TOKEN_CACHE"
      return 0
    fi
  fi

  # Refresh token
  local token
  token=$(~/google-cloud-sdk/bin/gcloud auth print-access-token 2>/dev/null) || {
    log_error "Failed to get gcloud access token — run: gcloud auth login"
    return 1
  }

  echo "$token" > "$TOKEN_CACHE"
  echo "$token"
}

# ── API Call Helper ───────────────────────────────────────
stitch_call() {
  local method="$1" arguments="$2"
  local token
  token=$(get_token) || return 1

  local response
  response=$(curl -s -m 120 -X POST \
    -H "Authorization: Bearer $token" \
    -H "x-goog-user-project: $GCP_PROJECT" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg method "$method" \
      --argjson args "$arguments" \
      '{jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: $method, arguments: $args}}'
    )" \
    "$STITCH_MCP_URL" 2>&1) || {
    log_error "Stitch API call failed: curl error"
    return 1
  }

  # Check for API error
  local error
  error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "$error" ]]; then
    log_error "Stitch API error: $error"
    echo "$response"
    return 1
  fi

  echo "$response"
}

# ── Parse Arguments ───────────────────────────────────────
COMMAND="${1:-}"
shift 2>/dev/null || true

PROMPT=""
DEVICE_TYPE="MOBILE"
INSTANCE_ID=""
SCREEN_ID=""
MODEL="GEMINI_3_1_PRO"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)       PROMPT="$2"; shift 2 ;;
    --device)       DEVICE_TYPE="$2"; shift 2 ;;
    --instance-id)  INSTANCE_ID="$2"; shift 2 ;;
    --screen-id)    SCREEN_ID="$2"; shift 2 ;;
    --model)        MODEL="$2"; shift 2 ;;
    *)              log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Commands ──────────────────────────────────────────────
case "$COMMAND" in
  generate)
    if [[ -z "$PROMPT" ]]; then
      log_error "generate requires --prompt"
      exit 1
    fi

    log_info "Generating Stitch screen (device=$DEVICE_TYPE, model=$MODEL)..."

    ARGS=$(jq -n \
      --arg pid "$STITCH_PROJECT_ID" \
      --arg prompt "$PROMPT" \
      --arg device "$DEVICE_TYPE" \
      --arg model "$MODEL" \
      '{projectId: $pid, prompt: $prompt, deviceType: $device, modelId: $model}')

    RESPONSE=$(stitch_call "generate_screen_from_text" "$ARGS") || exit 1

    # Extract screen IDs and screenshot URL
    python3 -c "
import sys, json
data = json.loads('''$(echo "$RESPONSE" | sed "s/'''/\\\\\"/g")''')
inner = json.loads(data['result']['content'][0]['text'])
comp = inner['outputComponents'][0]
screen = comp['design']['screens'][0]
result = {
    'screen_id': screen['name'],
    'instance_id': comp.get('screenInstanceId', ''),
    'screenshot_url': screen['screenshot']['downloadUrl'],
    'project_id': '$STITCH_PROJECT_ID'
}
print(json.dumps(result))
" 2>/dev/null || {
      log_error "Failed to parse Stitch response"
      echo "$RESPONSE" >&2
      exit 1
    }
    ;;

  apply-design-system)
    if [[ -z "$INSTANCE_ID" || -z "$SCREEN_ID" ]]; then
      log_error "apply-design-system requires --instance-id and --screen-id"
      exit 1
    fi

    log_info "Applying Helix Dark design system..."

    ARGS=$(jq -n \
      --arg pid "$STITCH_PROJECT_ID" \
      --arg dsid "$STITCH_DESIGN_SYSTEM_ID" \
      --arg iid "$INSTANCE_ID" \
      --arg sid "$SCREEN_ID" \
      '{projectId: $pid, assetId: $dsid, selectedScreenInstances: [{id: $iid, sourceScreen: $sid}]}')

    RESPONSE=$(stitch_call "apply_design_system" "$ARGS") || exit 1

    # Extract updated screenshot URL
    python3 -c "
import sys, json
data = json.loads('''$(echo "$RESPONSE" | sed "s/'''/\\\\\"/g")''')
inner = json.loads(data['result']['content'][0]['text'])
screens = inner['outputComponents'][0]['design']['screens']
result = {
    'screenshot_url': screens[0]['screenshot']['downloadUrl'],
    'design_system_applied': True
}
print(json.dumps(result))
" 2>/dev/null || {
      log_error "Failed to parse design system response"
      echo "$RESPONSE" >&2
      exit 1
    }
    ;;

  status)
    log_info "Checking Stitch API availability..."
    TOKEN=$(get_token) || { echo '{"status": "error", "reason": "token_failed"}'; exit 1; }
    # Simple health check — list projects
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 10 \
      -H "Authorization: Bearer $TOKEN" \
      -H "x-goog-user-project: $GCP_PROJECT" \
      "$STITCH_MCP_URL" 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "405" ]]; then
      echo '{"status": "ok", "project_id": "'"$STITCH_PROJECT_ID"'", "design_system_id": "'"$STITCH_DESIGN_SYSTEM_ID"'"}'
    else
      echo '{"status": "error", "http_code": "'"$HTTP_CODE"'", "reason": "api_unreachable"}'
      exit 1
    fi
    ;;

  *)
    echo "Usage: stitch-api.sh {generate|apply-design-system|status} [options]" >&2
    exit 1
    ;;
esac
