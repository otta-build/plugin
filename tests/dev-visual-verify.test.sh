#!/usr/bin/env bash
# Structural regression test for plugins/otta/commands/dev.md visual-verify step.
# Asserts /otta:dev wires the built-in `run` skill in as a frontend-only,
# pre-spec-review visual check, and that it's explicitly skippable for
# non-UI changes (so it doesn't slow down backend/CLI work).
# Run: bash plugins/otta/tests/dev-visual-verify.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_MD="$HERE/../commands/dev.md"

fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$DEV_MD" ] || fail "dev.md not found at $DEV_MD"

# 1. The `run` skill is invoked
grep -qi "\`run\` skill" "$DEV_MD" \
  || fail "dev.md does not invoke the \`run\` skill for visual verification"

# 2. It's scoped to frontend/UI changes only
grep -qiE "frontend|UI" "$DEV_MD" \
  || fail "dev.md does not scope the visual-verify step to frontend/UI changes"

# 3. It's explicitly skippable for non-UI work
grep -qi "skip this step" "$DEV_MD" \
  || fail "dev.md does not state the visual-verify step is skippable for non-UI changes"

# 4. It happens after Build and before Spec Review (ordering)
BUILD_LINE=$(grep -n "^3\. \*\*Build\.\*\*" "$DEV_MD" | head -1 | cut -d: -f1)
VERIFY_LINE=$(grep -n "Visual verify" "$DEV_MD" | head -1 | cut -d: -f1)
REVIEW_LINE=$(grep -n "^4\. \*\*Spec Review\.\*\*" "$DEV_MD" | head -1 | cut -d: -f1)
[ -n "$BUILD_LINE" ] || fail "could not locate the Build step"
[ -n "$VERIFY_LINE" ] || fail "could not locate the visual-verify step"
[ -n "$REVIEW_LINE" ] || fail "could not locate the Spec Review step"
[ "$BUILD_LINE" -lt "$VERIFY_LINE" ] || fail "visual-verify step is not after Build"
[ "$VERIFY_LINE" -lt "$REVIEW_LINE" ] || fail "visual-verify step is not before Spec Review"

echo "✓ dev-visual-verify: all 4 checks passed"
