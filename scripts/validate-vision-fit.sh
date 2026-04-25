#!/bin/bash
# validate-vision-fit.sh — confirm an epic card / PRD has a real Vision Fit section.
#
# The Helix product vision (`docs/product-vision.md`) defines five layers
# (Experience, Interpretation, Framework, Practice, Integration), eleven
# knowledge domains, and signature features. Every epic PRD must include a
# Vision Fit section that names which of these the epic strengthens.
#
# Scout's PRD template (references/agent-scout.md Phase 0) requires the
# section. This script is the mechanical enforcement: it greps the epic
# card body (and `docs/epics/<id>-<slug>/prd.md` if present) for the
# Vision Fit heading and checks that all three required prompts have
# substantive answers (not "TODO", not blank).
#
# Usage:
#   ./validate-vision-fit.sh --card <N>
#   ./validate-vision-fit.sh --prd-file docs/epics/148-insights-v2/prd.md
#
# Exit:
#   0 — Vision Fit section is present and filled
#   1 — Vision Fit section is missing or contains placeholders / blanks
#
# Output: JSON { card, has_section, layer_named, domain_named, feature_named, ok, reasons[] }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

show_help_if_requested "$@" <<'HELP'
validate-vision-fit.sh — enforce that every epic PRD names what it strengthens.

Usage:
  ./validate-vision-fit.sh --card <N>
  ./validate-vision-fit.sh --prd-file <path>

Exit 0 when section is present and substantive, 1 otherwise.
HELP

CARD=""
PRD_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --card)     CARD="$2"; shift 2 ;;
    --prd-file) PRD_FILE="$2"; shift 2 ;;
    *)          log_error "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$CARD" && -z "$PRD_FILE" ]] && { log_error "--card or --prd-file required"; exit 1; }

# ── Source body ─────────────────────────────────────────
BODY=""
if [[ -n "$PRD_FILE" ]]; then
  [[ -f "$PRD_FILE" ]] || { log_error "PRD file not found: $PRD_FILE"; exit 1; }
  BODY=$(cat "$PRD_FILE")
elif [[ -n "$CARD" ]]; then
  BODY=$(gh issue view "$CARD" --repo "$REPO" --json body -q '.body' 2>/dev/null || echo "")
  if [[ -z "$BODY" ]]; then
    log_error "Could not fetch issue #$CARD body"
    exit 1
  fi
fi

# ── Locate the Vision Fit section ───────────────────────
# Section starts at "## Vision Fit" and ends at the next "## " heading or EOF.
SECTION=$(echo "$BODY" | awk '
  /^## Vision Fit/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section { print }
')

REASONS=()
HAS_SECTION="false"
LAYER_NAMED="false"
DOMAIN_NAMED="false"
FEATURE_NAMED="false"

if [[ -n "$SECTION" ]]; then
  HAS_SECTION="true"
else
  REASONS+=("Missing '## Vision Fit' heading in the epic body / PRD")
fi

# ── Check 1: at least one of the five layers is named ──
if echo "$SECTION" | grep -qiE '\b(Experience|Interpretation|Framework|Practice|Integration)\b'; then
  LAYER_NAMED="true"
else
  REASONS+=("Vision Fit must name at least one of the five layers (Experience, Interpretation, Framework, Practice, Integration)")
fi

# ── Check 2: at least one knowledge domain is named ────
DOMAIN_PATTERN='\b(Psychology|Mysticism|Philosophy|Mythology|Religion|Shamanism|Alchemy|Astrology|Psychedelics|Science|AI)\b'
if echo "$SECTION" | grep -qiE "$DOMAIN_PATTERN"; then
  DOMAIN_NAMED="true"
else
  REASONS+=("Vision Fit must name at least one knowledge domain as an interpretive engine (Psychology, Mysticism, Philosophy, Mythology, Religion, Shamanism, Alchemy, Astrology, Psychedelics, Science, or AI)")
fi

# ── Check 3: at least one signature feature is named ───
SIGNATURE_PATTERN='\b(symbolic atlas|multi-?lens|archetypal cast|framework builder|map(s)? of consciousness|recursive pattern|integration tracking|phase-based)\b'
if echo "$SECTION" | grep -qiE "$SIGNATURE_PATTERN"; then
  FEATURE_NAMED="true"
else
  REASONS+=("Vision Fit must name at least one signature feature it deepens (symbolic atlas, multi-lens interpretation, archetypal cast, framework builder, maps of consciousness, recursive pattern detection, integration tracking, or phase-based recommendations)")
fi

# ── Check 4: section content is substantive (not placeholder) ─
if echo "$SECTION" | grep -qiE 'TODO|TBD|placeholder|fill me in|n/a$|^_.*_$'; then
  REASONS+=("Vision Fit section contains placeholder text (TODO/TBD/N/A) — fill it in")
fi

OK="true"
if [[ "$HAS_SECTION" != "true" || "$LAYER_NAMED" != "true" || "$DOMAIN_NAMED" != "true" || "$FEATURE_NAMED" != "true" || ${#REASONS[@]} -gt 0 ]]; then
  OK="false"
fi

REASONS_JSON=$(printf '%s\n' "${REASONS[@]+"${REASONS[@]}"}" | jq -R . | jq -s '.')

jq -n \
  --arg card "${CARD:-}" \
  --arg prd "${PRD_FILE:-}" \
  --argjson has "$HAS_SECTION" \
  --argjson layer "$LAYER_NAMED" \
  --argjson domain "$DOMAIN_NAMED" \
  --argjson feature "$FEATURE_NAMED" \
  --argjson ok "$OK" \
  --argjson reasons "$REASONS_JSON" \
  '{
    card: $card,
    prd_file: $prd,
    has_section: $has,
    layer_named: $layer,
    domain_named: $domain,
    feature_named: $feature,
    ok: $ok,
    reasons: $reasons
  }'

[[ "$OK" == "true" ]] && exit 0 || exit 1
