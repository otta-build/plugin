#!/usr/bin/env bash
# Structural regression test for plugins/otta/commands/fix.md (#69).
# Asserts that fix.md exists and contains the mandatory invariants:
#   1. the gate step is present (AC1)
#   2. idea_ref + Fixes linkage requirements are stated (AC1)
#   3. the never-direct-to-main / never-ungated invariant is explicit (AC2)
#   4. the tier rule is documented (AC3)
#   5. the branch-protection cross-reference to #75/#65 is present (AC4 cross-ref)
# Run: bash plugins/otta/tests/fix-command.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_MD="$HERE/../commands/fix.md"

fail() { echo "✗ $1" >&2; exit 1; }

# 1. fix.md exists
[ -f "$FIX_MD" ] || fail "fix.md not found at $FIX_MD (AC1)"

# 2. Gate step is present (otta-gate.sh invocation documented)
grep -qi "otta-gate" "$FIX_MD" \
  || fail "fix.md does not reference the gate step (otta-gate.sh) — AC1 requires gate + PR"

# 3. idea_ref and Fixes linkage requirements are stated (AC1)
grep -qi "idea_ref" "$FIX_MD" \
  || fail "fix.md does not mention idea_ref — lifecycle linkage is required by AC1"
grep -qiE "Fixes #" "$FIX_MD" \
  || fail "fix.md does not mention 'Fixes #' linkage — lifecycle linkage is required by AC1"

# 4. Never-direct-to-main / never-ungated invariant (AC2)
grep -qiE "direct.to.main|never.*direct" "$FIX_MD" \
  || fail "fix.md does not explicitly state the never-direct-to-main invariant (AC2)"
grep -qi "ungated\|never.*gate\|still.*gate\|gate.*still" "$FIX_MD" \
  || fail "fix.md does not explicitly state the never-ungated invariant (AC2)"

# 5. Tier rule is documented (AC3)
grep -qiE "tiny|tier|otta:dev|otta:build" "$FIX_MD" \
  || fail "fix.md does not document the tier rule (AC3)"

# 6. cavecrew-builder is named and tied to execution cost only, never the gate (AC3)
grep -qi "cavecrew" "$FIX_MD" \
  || fail "fix.md does not mention cavecrew-builder — AC3 requires it be named (execution cost only, never skips gate)"

# 7. Cross-reference to branch-protection issue #75 or #65 (AC4 cross-ref only)
grep -qE "#75|#65" "$FIX_MD" \
  || fail "fix.md missing cross-reference to #75/#65 for branch-protection (AC4 one-liner)"

echo "✓ fix-command: all 7 checks passed"
