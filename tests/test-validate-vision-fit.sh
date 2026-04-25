#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/validate-vision-fit.sh"

PASS=0; FAIL=0
report_pass() { PASS=$((PASS+1)); }
report_fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
expect_exit() {
  local label="$1" expected="$2"; shift 2
  set +e
  bash "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [[ "$actual" == "$expected" ]]; then
    report_pass
  else
    report_fail "$label: expected exit $expected, got $actual"
  fi
}

# ── Good PRD (all three named) ──────────────────────────
cat > /tmp/vfit-good.md <<'EOF'
# PRD: Symbolic atlas v2

## Vision Fit
- Layer: Interpretation
- Domain: Psychology, Mythology
- Strengthens the symbolic atlas

## Other section
EOF
expect_exit "good_prd" 0 "$SCRIPT" --prd-file /tmp/vfit-good.md

# ── Missing section ─────────────────────────────────────
cat > /tmp/vfit-missing.md <<'EOF'
# PRD: x

## Other section
EOF
expect_exit "missing_section" 1 "$SCRIPT" --prd-file /tmp/vfit-missing.md

# ── Missing layer ───────────────────────────────────────
cat > /tmp/vfit-no-layer.md <<'EOF'
## Vision Fit
Domain: Psychology. Strengthens symbolic atlas.
EOF
expect_exit "missing_layer" 1 "$SCRIPT" --prd-file /tmp/vfit-no-layer.md

# ── Missing domain ──────────────────────────────────────
cat > /tmp/vfit-no-domain.md <<'EOF'
## Vision Fit
Layer: Interpretation. Strengthens symbolic atlas.
EOF
expect_exit "missing_domain" 1 "$SCRIPT" --prd-file /tmp/vfit-no-domain.md

# ── Missing signature feature ───────────────────────────
cat > /tmp/vfit-no-feature.md <<'EOF'
## Vision Fit
Layer: Practice. Domain: Psychology. Generic recommendation surface.
EOF
expect_exit "missing_feature" 1 "$SCRIPT" --prd-file /tmp/vfit-no-feature.md

# ── Placeholder text rejected ───────────────────────────
cat > /tmp/vfit-todo.md <<'EOF'
## Vision Fit
- Layer: Practice
- Domain: Psychology
- TODO: fill in signature feature
EOF
expect_exit "placeholder_rejected" 1 "$SCRIPT" --prd-file /tmp/vfit-todo.md

# ── Multi-lens recognized ───────────────────────────────
cat > /tmp/vfit-multilens.md <<'EOF'
## Vision Fit
Layer: Interpretation. Domain: Mysticism. Strengthens multi-lens interpretation.
EOF
expect_exit "multilens_feature" 0 "$SCRIPT" --prd-file /tmp/vfit-multilens.md

# ── No args fails ───────────────────────────────────────
expect_exit "no_args" 1 "$SCRIPT"

# Cleanup
rm -f /tmp/vfit-*.md

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
