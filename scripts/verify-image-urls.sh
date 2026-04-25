#!/bin/bash
# verify-image-urls.sh — HEAD-check every image/media URL in a payload before posting.
#
# Broken images must never ship in PR bodies or comments. Run this on any draft
# body/comment file before handing it to `gh pr edit --body-file` or
# `gh pr comment --body-file`.
#
# Usage:
#   ./verify-image-urls.sh <file>
#
# Exit codes:
#   0 — all URLs reachable (or none found)
#   2 — at least one URL is broken (missing release asset, malformed, 4xx/5xx)
#
# Output: JSON report on stdout, human log on stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <payload-file>" >&2
  exit 1
fi

FILE="$1"
if [[ ! -f "$FILE" ]]; then
  echo "File not found: $FILE" >&2
  exit 1
fi

REPO="${GH_REPO:-amonick12/helix}"
TOKEN="$(gh auth token 2>/dev/null || true)"

# Cache of release asset names for the screenshots release, populated lazily.
ASSET_CACHE=""
load_release_assets() {
  if [[ -z "$ASSET_CACHE" ]]; then
    ASSET_CACHE="$(gh release view screenshots --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)"
  fi
}

# Extract image/media URLs from markdown + HTML inside the payload.
urls="$(grep -oE 'https?://[^[:space:]"'\''<>)]+' "$FILE" \
  | awk '{
      u=$0;
      # strip trailing punctuation picked up by the regex
      sub(/[.,;:)\]]+$/, "", u);
      lu = tolower(u);
      if (lu ~ /\.(png|jpe?g|gif|webp|svg|mov|mp4|m4v|webm)(\?|$)/ \
          || lu ~ /releases\/download\// \
          || lu ~ /user-attachments\// \
          || lu ~ /githubusercontent\.com/ \
          || lu ~ /lh[0-9]+\.googleusercontent/) {
        print u;
      }
    }' | awk '!seen[$0]++' )"

total=0
broken_json="[]"

if [[ -n "$urls" ]]; then
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    total=$((total + 1))
    reason=""

    # ── Syntactic checks ────────────────────────────────────
    # Duplicate query flags (e.g. ?raw=true?raw=true) break GitHub.
    if grep -qE '\?raw=true\?' <<<"$url"; then
      reason="malformed: duplicate ?raw=true in query string"
    elif grep -qE '[?&]([a-zA-Z0-9_-]+)=[^&]*[?&]\1=' <<<"$url"; then
      reason="malformed: duplicate query key"
    fi

    # ── Release-asset existence check ───────────────────────
    if [[ -z "$reason" && "$url" =~ /releases/download/screenshots/ ]]; then
      name="${url#*/releases/download/screenshots/}"
      name="${name%%\?*}"
      name="${name%%#*}"
      load_release_assets
      if ! grep -qxF "$name" <<<"$ASSET_CACHE"; then
        reason="missing from 'screenshots' release: $name"
      fi
    fi

    # ── HTTP reachability (best-effort) ─────────────────────
    # Skip HTTP check for verified release-download URLs: GitHub's direct
    # /releases/download/ endpoint returns 404 to curl on private repos even
    # with a token — the browser uses a separate cookie-auth proxy. We already
    # confirmed the asset exists in the release manifest above.
    if [[ -z "$reason" && ! "$url" =~ /releases/download/screenshots/ ]]; then
      if [[ -n "$TOKEN" && "$url" == *"github.com"* ]]; then
        code="$(curl -sSIL -H "Authorization: token $TOKEN" -H "Accept: application/octet-stream" \
                    -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || echo 000)"
      else
        code="$(curl -sSIL -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || echo 000)"
      fi
      case "$code" in
        200|301|302|303) : ;;
        000) reason="unreachable (curl code 000): $url" ;;
        404) reason="HTTP 404: $url" ;;
        4*|5*) reason="HTTP $code: $url" ;;
      esac
    fi

    if [[ -n "$reason" ]]; then
      echo "  BROKEN: $reason" >&2
      broken_json="$(jq -c --arg u "$url" --arg r "$reason" '. + [{url:$u, reason:$r}]' <<<"$broken_json")"
    fi
  done <<< "$urls"
fi

broken_count="$(jq 'length' <<<"$broken_json")"

jq -n --argjson total "$total" --argjson broken "$broken_json" \
  '{total_urls:$total, broken_count:($broken|length), broken:$broken}'

if [[ "$broken_count" -gt 0 ]]; then
  echo "Image URL verification FAILED: $broken_count broken URL(s)." >&2
  exit 2
fi

echo "Image URL verification OK ($total URL(s) checked)." >&2
exit 0
