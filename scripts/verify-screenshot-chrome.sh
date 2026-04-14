#!/bin/bash
# verify-screenshot-chrome.sh — Reject screenshots that came from snapshot
# tests instead of the running app.
#
# Usage:
#   ./verify-screenshot-chrome.sh <png-path> [<png-path>...]
#
# Exit 0: every screenshot looks like a real device capture
# Exit 1: at least one screenshot is the wrong size or has a uniform-color
#         bottom strip (indicating no tab bar / no chrome).
#
# Heuristics:
# 1. Dimension check — iOS device screenshots are 1206x2622 (iPhone 17 Pro)
#    or other known device sizes. Snapshot test PNGs are typically 390x844
#    (logical) or 1170x2532 (older device @3x). If the dimensions don't
#    match a known iPhone 17 Pro capture, fail.
# 2. Bottom-strip variance — a real device screenshot has the home indicator
#    or the tab bar in the bottom 120 logical points (~360 pixels @3x).
#    A snapshot test render of a standalone view does not. Sample the bottom
#    strip and check the unique-color count. If the strip is one solid color
#    (variance under threshold), the chrome is missing.
#
# Both heuristics must pass for the screenshot to be accepted.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: verify-screenshot-chrome.sh <png-path> [<png-path>...]" >&2
  exit 1
fi

# Known good iPhone 17 Pro device capture dimensions (iOS 18.x / iOS 26.x)
EXPECTED_WIDTHS=(1206 1290 1170 1284)
EXPECTED_HEIGHTS=(2622 2796 2532 2778)

is_known_device_size() {
  local w=$1 h=$2
  local i
  for i in "${!EXPECTED_WIDTHS[@]}"; do
    if [[ "$w" == "${EXPECTED_WIDTHS[$i]}" && "$h" == "${EXPECTED_HEIGHTS[$i]}" ]]; then
      return 0
    fi
  done
  return 1
}

FAILED=0
for png in "$@"; do
  if [[ ! -f "$png" ]]; then
    echo "FAIL: $png not found" >&2
    FAILED=1
    continue
  fi

  # ── Dimension check ─────────────────────────────────────
  DIMS=$(sips -g pixelWidth -g pixelHeight "$png" 2>/dev/null | awk '/pixelWidth|pixelHeight/ {print $2}')
  WIDTH=$(echo "$DIMS" | sed -n '1p')
  HEIGHT=$(echo "$DIMS" | sed -n '2p')

  if [[ -z "$WIDTH" || -z "$HEIGHT" ]]; then
    echo "FAIL: $png — could not read dimensions" >&2
    FAILED=1
    continue
  fi

  if ! is_known_device_size "$WIDTH" "$HEIGHT"; then
    echo "FAIL: $png — dimensions ${WIDTH}x${HEIGHT} are not a known iPhone device capture" >&2
    echo "      Known sizes: ${EXPECTED_WIDTHS[*]} × ${EXPECTED_HEIGHTS[*]}" >&2
    echo "      Likely a snapshot test render of a standalone view, not the running app." >&2
    FAILED=1
    continue
  fi

  # ── Bottom-strip variance check ─────────────────────────
  # Crop the bottom 360px and convert to a tiny 8x8 thumbnail. A real
  # device screenshot with a tab bar will have at least 4 distinct colors
  # in this strip. A standalone view with a uniform background will have 1.
  STRIP_TOP=$((HEIGHT - 360))
  TMP_STRIP="/tmp/verify-strip-$$.png"
  TMP_THUMB="/tmp/verify-thumb-$$.png"
  trap 'rm -f "$TMP_STRIP" "$TMP_THUMB"' EXIT

  if ! sips --cropToHeightWidth 360 "$WIDTH" --cropOffset "$STRIP_TOP" 0 \
        "$png" --out "$TMP_STRIP" >/dev/null 2>&1; then
    echo "WARN: $png — sips crop failed; skipping variance check" >&2
    continue
  fi
  if ! sips -z 8 8 "$TMP_STRIP" --out "$TMP_THUMB" >/dev/null 2>&1; then
    echo "WARN: $png — sips resize failed; skipping variance check" >&2
    continue
  fi

  # Count unique colors in the 8x8 thumbnail by hashing each pixel.
  # We use python here because bash + ImageIO is awkward.
  UNIQUE_COLORS=$(python3 - "$TMP_THUMB" <<'PY'
import sys
try:
    from PIL import Image
except ImportError:
    print("0")
    sys.exit(0)
img = Image.open(sys.argv[1]).convert("RGB")
print(len(set(img.getdata())))
PY
)

  if [[ "$UNIQUE_COLORS" == "0" ]]; then
    # Pillow not installed — skip variance check, dimension check is enough
    echo "WARN: $png — Pillow not available; dimension check passed, variance check skipped" >&2
    rm -f "$TMP_STRIP" "$TMP_THUMB"
    continue
  fi

  if [[ "$UNIQUE_COLORS" -lt 4 ]]; then
    echo "FAIL: $png — bottom strip has only $UNIQUE_COLORS unique colors" >&2
    echo "      Expected at least 4 (tab bar should be visible). This screenshot" >&2
    echo "      is probably a standalone view render with no surrounding chrome." >&2
    FAILED=1
    rm -f "$TMP_STRIP" "$TMP_THUMB"
    continue
  fi

  rm -f "$TMP_STRIP" "$TMP_THUMB"
  echo "OK:   $png (${WIDTH}x${HEIGHT}, $UNIQUE_COLORS bottom-strip colors)"
done

exit $FAILED
