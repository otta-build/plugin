#!/usr/bin/env bash
# Regression test for the stale-issue guard in scripts/check-pr-body.sh.
# Bug: a tracked .pr-body.md left over from a previously merged PR (Fixes an
# issue that's now CLOSED) was silently reused for a new, unrelated PR because
# the gate only checked structure, never whether the linked issue was stale.
# Run: bash plugins/otta/tests/check-pr-body-stale-issue.test.sh
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

fake_gh() {
  local state="$1"
  mkdir -p "$TMPDIR/bin"
  cat > "$TMPDIR/bin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then exit 0; fi
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then echo '{"state":"$state"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'; exit 0; fi
exit 1
EOF
  chmod +x "$TMPDIR/bin/gh"
}

# 1. Fixes a CLOSED issue → gate must fail with the stale-body message
make_body 17
fake_gh "CLOSED"
if PATH="$TMPDIR/bin:$PATH" bash "$CHECK" "$TMPDIR/pr-body.md" >"$TMPDIR/out1.log" 2>&1; then
  cat "$TMPDIR/out1.log" >&2
  fail "expected failure for a Fixes-closed-issue body, but check-pr-body.sh passed"
fi
grep -qi "already CLOSED" "$TMPDIR/out1.log" || { cat "$TMPDIR/out1.log" >&2; fail "failure message doesn't mention the closed-issue reason"; }

# 2. Fixes an OPEN issue → gate must pass
make_body 76
fake_gh "OPEN"
PATH="$TMPDIR/bin:$PATH" bash "$CHECK" "$TMPDIR/pr-body.md" >"$TMPDIR/out2.log" 2>&1 \
  || { cat "$TMPDIR/out2.log" >&2; fail "expected pass for a Fixes-open-issue body"; }

# 3. gh unavailable → degrade gracefully, still pass (no network dependency offline)
make_body 17
PATH="/usr/bin:/bin" bash "$CHECK" "$TMPDIR/pr-body.md" >"$TMPDIR/out3.log" 2>&1 \
  || { cat "$TMPDIR/out3.log" >&2; fail "expected pass when gh is unavailable (best-effort check only)"; }

echo "✓ check-pr-body-stale-issue: all 3 checks passed"
