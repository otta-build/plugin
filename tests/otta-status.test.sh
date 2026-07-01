#!/usr/bin/env bash
# otta-status.test.sh — AC4: checklist rendering (Idea → Build → Gate → CI → Release/Deploy)
# with pass/fail/pending markers, driven by scripts/otta-status.sh
# Run: bash tests/otta-status.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-status.sh"
fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$SCRIPT" ] || fail "otta-status.sh not found at $SCRIPT"
command -v jq >/dev/null || fail "jq required to run this test"

# =============================================================================
# 1. All-pass input renders all ✓ markers and a summary line
# =============================================================================
ALL_PASS='{
  "issue": "82",
  "stages": {
    "idea":    {"status": "pass", "detail": "issue #82 open"},
    "build":   {"status": "pass", "detail": "PR #90 open"},
    "gate":    {"status": "pass", "detail": "Otta Gate green"},
    "ci":      {"status": "pass", "detail": "CI green"},
    "release": {"status": "pass", "detail": "merged + tagged v1.2.0"}
  }
}'
OUTPUT="$(printf '%s' "$ALL_PASS" | bash "$SCRIPT" 2>&1)" || fail "script failed on all-pass input:\n$OUTPUT"
echo "$OUTPUT" | grep -q "Idea" || fail "missing Idea stage in output"
echo "$OUTPUT" | grep -q "Build" || fail "missing Build stage in output"
echo "$OUTPUT" | grep -q "Gate" || fail "missing Gate stage in output"
echo "$OUTPUT" | grep -q "CI" || fail "missing CI stage in output"
echo "$OUTPUT" | grep -q "Release" || fail "missing Release/Deploy stage in output"
CHECK_COUNT="$(echo "$OUTPUT" | grep -o '✓' | wc -l | tr -d ' ')"
[ "$CHECK_COUNT" -ge 5 ] || fail "expected at least 5 ✓ markers, got $CHECK_COUNT:\n$OUTPUT"
echo "  ✓ all-pass renders 5 ✓ markers"

# =============================================================================
# 2. Mixed status renders the right marker per stage (✓ / ✗ / ○)
# =============================================================================
MIXED='{
  "issue": "82",
  "stages": {
    "idea":    {"status": "pass",    "detail": "issue #82 open"},
    "build":   {"status": "pass",    "detail": "PR #90 open"},
    "gate":    {"status": "fail",    "detail": "Otta Gate: 2/3 sub-checks failing"},
    "ci":      {"status": "pending", "detail": "CI: queued"},
    "release": {"status": "pending", "detail": "not merged yet"}
  }
}'
OUTPUT="$(printf '%s' "$MIXED" | bash "$SCRIPT" 2>&1)" || fail "script failed on mixed input:\n$OUTPUT"

echo "$OUTPUT" | grep -qE '✓[[:space:]]+Idea' || fail "Idea should be ✓:\n$OUTPUT"
echo "$OUTPUT" | grep -qE '✓[[:space:]]+Build' || fail "Build should be ✓:\n$OUTPUT"
echo "$OUTPUT" | grep -qE '✗[[:space:]]+Gate' || fail "Gate should be ✗:\n$OUTPUT"
echo "$OUTPUT" | grep -qE '○[[:space:]]+CI' || fail "CI should be ○ (pending):\n$OUTPUT"
echo "$OUTPUT" | grep -qE '○[[:space:]]+Release' || fail "Release/Deploy should be ○ (pending):\n$OUTPUT"
echo "  ✓ mixed status renders correct per-stage markers"

# =============================================================================
# 3. Detail text for each stage is included in the output
# =============================================================================
echo "$OUTPUT" | grep -q "Otta Gate: 2/3 sub-checks failing" \
  || fail "gate detail text missing from output:\n$OUTPUT"
echo "$OUTPUT" | grep -q "not merged yet" \
  || fail "release detail text missing from output:\n$OUTPUT"
echo "  ✓ per-stage detail text present"

# =============================================================================
# 4. Issue number is echoed in the header
# =============================================================================
echo "$OUTPUT" | grep -q "82" || fail "issue number not echoed in output:\n$OUTPUT"
echo "  ✓ issue number present in header"

# =============================================================================
# 5. Invalid JSON input fails loudly (exit non-zero), doesn't silently pass
# =============================================================================
if printf 'not json' | bash "$SCRIPT" > /dev/null 2>&1; then
  fail "script should exit non-zero on invalid JSON input"
fi
echo "  ✓ invalid JSON input rejected"

echo "✓ otta-status: all checks passed (all-pass render, mixed markers, detail text, header, invalid-input guard)"
