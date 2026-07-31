#!/usr/bin/env bash
# Regression test for stale-body detection that does not depend on the network.
#
# Bug 1: the only staleness check in check-pr-body.sh asks GitHub whether the
# linked issue is CLOSED. That misses the common case entirely — a body left
# over from an earlier PR whose issue is still OPEN sails through, and it can
# only ever catch staleness after the fact.
#
# Bug 2: that check is wrapped in `|| true` at every step, so when `gh` is
# absent, unauthenticated, or offline it reports nothing and the gate passes.
# An absent verdict is silently indistinguishable from a clean one.
#
# Fix: when the caller knows which issue this run is for, it exports
# OTTA_EXPECTED_ISSUE. check-pr-body.sh then asserts `Fixes #N` matches it —
# locally, deterministically, no network. And when a stale-check cannot reach
# gh, that is reported rather than swallowed.
# Run: bash plugins/otta/tests/check-pr-body-expected-issue.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../scripts/check-pr-body.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail() { echo "✗ $1" >&2; exit 1; }

make_body() {
  cat > "$TMPDIR/pr-body.md" <<EOF
## Summary
- test

\`\`\`acceptance
GIVEN x
WHEN y
THEN z
- [x] AC1: done
\`\`\`

idea_ref: issue:#$1

Fixes #$1
EOF
}

# A PATH with no `gh` at all — proves every assertion below is offline.
NOGH="$TMPDIR/nogh"
mkdir -p "$NOGH"
for b in bash sh grep sed cat head tr git; do
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$NOGH/$b"
done

run_check() {
  # $1 = expected issue (empty to leave the var unset)
  if [ -n "${1:-}" ]; then
    env -i PATH="$NOGH" OTTA_EXPECTED_ISSUE="$1" bash "$CHECK" "$TMPDIR/pr-body.md" >/dev/null 2>&1
  else
    env -i PATH="$NOGH" bash "$CHECK" "$TMPDIR/pr-body.md" >/dev/null 2>&1
  fi
}

# 1. Body matches the expected issue → pass.
make_body 176
rc=0; run_check 176 || rc=$?
[ "$rc" -eq 0 ] || fail "matching Fixes #176 with OTTA_EXPECTED_ISSUE=176 should pass, got $rc"

# 2. Body is for a DIFFERENT issue than this run → the stale case. Must fail,
#    with no network involved and regardless of whether #65 is open or closed.
make_body 65
rc=0; run_check 176 || rc=$?
[ "$rc" -ne 0 ] || fail "stale body (Fixes #65) with OTTA_EXPECTED_ISSUE=176 must fail, got 0"

# 3. The failure must name both numbers so the fix is obvious.
msg="$(env -i PATH="$NOGH" OTTA_EXPECTED_ISSUE=176 bash "$CHECK" "$TMPDIR/pr-body.md" 2>&1 || true)"
printf '%s' "$msg" | grep -q "65" || fail "mismatch message must name the body's issue 65; got: $msg"
printf '%s' "$msg" | grep -q "176" || fail "mismatch message must name the expected issue 176; got: $msg"

# 4. Unset OTTA_EXPECTED_ISSUE → assertion is skipped, structure still checked.
#    Keeps every existing caller working unchanged.
make_body 65
rc=0; run_check "" || rc=$?
[ "$rc" -eq 0 ] || fail "without OTTA_EXPECTED_ISSUE a structurally-valid body should pass, got $rc"

# 5. A structurally broken body still fails when the issue number matches.
cat > "$TMPDIR/pr-body.md" <<'EOF'
## Summary
- no acceptance block, no idea_ref

Fixes #176
EOF
rc=0; run_check 176 || rc=$?
[ "$rc" -ne 0 ] || fail "structurally invalid body must still fail even when the issue matches"

echo "✓ check-pr-body asserts Fixes #N against OTTA_EXPECTED_ISSUE offline"
