#!/usr/bin/env bash
# Regression test for pre-push-guard.sh checking .pr-body.md relative to CWD
# instead of the actual git repo toplevel. When an agent's CWD is inside a
# nested git repo (or the parent of one), a stale/foreign .pr-body.md from
# the OTHER repo could be picked up, causing false blocks or false passes.
# Run: bash plugins/otta/tests/pre-push-guard-nested.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../hooks/pre-push-guard.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail() { echo "✗ $1" >&2; exit 1; }

stale_body() {
  cat <<'EOF'
## Summary
- stale

\`\`\`acceptance
GIVEN x
WHEN y
THEN z
- [x] AC1: done
\`\`\`

idea_ref: issue:#99

Fixes #99
EOF
}

# 1. Nested repo has a stale .pr-body.md; parent repo (no .pr-body.md) pushes
#    from its own toplevel. The nested repo's file must NOT block the parent.
PARENT="$TMPDIR/parent"
mkdir -p "$PARENT"
(cd "$PARENT" && git init -q)

NESTED="$PARENT/nested"
mkdir -p "$NESTED"
(cd "$NESTED" && git init -q)
stale_body > "$NESTED/.pr-body.md"

rc1=0
out1="$(cd "$PARENT" && echo '{"tool_input":{"command":"git push origin main"}}' | bash "$GUARD" 2>&1)" || rc1=$?
[ "$rc1" -eq 0 ] || { echo "$out1" >&2; fail "expected exit 0 for parent push (no .pr-body.md at parent toplevel), got $rc1"; }

# 2. Parent repo has a stale .pr-body.md; nested repo (no .pr-body.md) pushes
#    from its own toplevel. The parent repo's file must NOT block the nested repo.
PARENT2="$TMPDIR/parent2"
mkdir -p "$PARENT2"
(cd "$PARENT2" && git init -q)
stale_body > "$PARENT2/.pr-body.md"

NESTED2="$PARENT2/nested"
mkdir -p "$NESTED2"
(cd "$NESTED2" && git init -q)

rc2=0
out2="$(cd "$NESTED2" && echo '{"tool_input":{"command":"git push origin main"}}' | bash "$GUARD" 2>&1)" || rc2=$?
[ "$rc2" -eq 0 ] || { echo "$out2" >&2; fail "expected exit 0 for nested push (no .pr-body.md at nested toplevel), got $rc2"; }

echo "✓ pre-push-guard-nested: all 2 checks passed"
