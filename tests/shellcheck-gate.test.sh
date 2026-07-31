#!/usr/bin/env bash
# Regression test for the shellcheck CI gate (#177).
#
# Before this, .github/workflows/ci.yml was 35 lines with a single step — loop
# tests/*.test.sh — and there was no static analysis over 5,000+ lines of bash
# across 32 scripts and 3 hooks. Five scripts already carried `# shellcheck`
# directives, so the intent existed; the wiring never landed.
#
# The bug class this catches, from this repo's own history: otta-worktree.sh
# --prune used BSD-first `stat -f %m`, which on Linux silently succeeds as
# --file-system, yielding a garbage mtime that aborted the script under `set -u`.
#
# This test guards two things that can rot independently:
#   1. the workflow still runs shellcheck as a BLOCKING warning-severity gate
#   2. the tree is actually clean at that severity, so the gate stays meaningful
# Run: bash plugins/otta/tests/shellcheck-gate.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CI="$REPO/.github/workflows/ci.yml"

fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$CI" ] || fail ".github/workflows/ci.yml is missing"

# 1. The workflow invokes shellcheck at warning severity.
grep -qE 'shellcheck .*--severity=warning' "$CI" \
  || fail "ci.yml must run shellcheck with --severity=warning as a blocking gate"

# 2. That invocation must NOT be neutered with `|| true` on the same line —
#    a gate that cannot fail is not a gate.
if grep -E 'shellcheck .*--severity=warning' "$CI" | grep -q '|| *true'; then
  fail "the warning-severity shellcheck run must not be suppressed with '|| true'"
fi

# 3. A separate non-blocking report surfaces warning/info/style findings.
grep -qE 'shellcheck .*--severity=(style|info)' "$CI" \
  || fail "ci.yml should also run a non-blocking shellcheck report for lower severities"

# 4. Both runs cover scripts/ and hooks/.
for dir in 'scripts/\*\.sh' 'hooks/\*\.sh'; do
  grep -qE "shellcheck.*$dir" "$CI" \
    || fail "ci.yml shellcheck invocation must cover $(printf '%b' "$dir" | tr -d '\\')"
done

# 5. The Python implementation is excluded by targeting *.sh explicitly rather
#    than by a blanket suppression directive inside the file.
if grep -q 'shellcheck disable=all' "$REPO/scripts/otta-learning-policy.py" 2>/dev/null; then
  fail "otta-learning-policy.py must be excluded by file glob, not a blanket disable"
fi

# 6. The tree is clean at warning severity. Skip (don't fail) when shellcheck is
#    absent locally — CI installs it, and a missing linter is not a defect in
#    the code under test. The skip is reported, never silent.
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "⚠ shellcheck not installed locally — skipped the clean-tree assertion (CI still enforces it)"
  echo "✓ shellcheck gate is wired in ci.yml"
  exit 0
fi

cd "$REPO"
if ! out="$(shellcheck --severity=warning --format=gcc scripts/*.sh hooks/*.sh 2>&1)"; then
  echo "✗ shellcheck reports warning-severity findings:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

echo "✓ shellcheck gate is wired in ci.yml and the tree is clean at warning severity"
