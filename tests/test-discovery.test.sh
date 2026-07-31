#!/usr/bin/env bash
# Regression test: every *.test.sh in the repo must be somewhere CI runs it.
#
# Bug: .github/workflows/ci.yml discovers tests with `for t in tests/*.test.sh`.
# hooks/subagent-gate-guard.test.sh lived in hooks/, so it had never once been
# executed by CI. It passed, but nothing enforced that — and it covers the
# SubagentStop gate hook, one of the two points that stop a build stage
# reporting "done" past a failing gate.
#
# A test nobody runs is worse than no test: it reads as coverage on the file
# listing while proving nothing.
# Run: bash plugins/otta/tests/test-discovery.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CI="$REPO/.github/workflows/ci.yml"

fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$CI" ] || fail ".github/workflows/ci.yml is missing"

# The glob CI actually iterates. Pinned so that widening or narrowing the
# workflow's discovery without updating this test is itself a failure.
grep -qF 'for t in tests/*.test.sh' "$CI" \
  || fail "ci.yml no longer iterates 'tests/*.test.sh' — update this test to match the new discovery rule"

# Every *.test.sh must sit directly in tests/, or CI will not see it.
# .git is excluded; nothing else is.
orphans="$(
  cd "$REPO"
  find . -name '*.test.sh' -type f -not -path './.git/*' \
    | sed 's|^\./||' \
    | grep -v '^tests/[^/]*\.test\.sh$' \
    || true
)"

if [ -n "$orphans" ]; then
  echo "✗ these *.test.sh files are never executed by CI:" >&2
  printf '%s\n' "$orphans" | sed 's/^/    /' >&2
  echo "  Move them to tests/ (flat), or change ci.yml discovery and this test together." >&2
  exit 1
fi

count="$(cd "$REPO" && find tests -maxdepth 1 -name '*.test.sh' -type f | wc -l | tr -d ' ')"
echo "✓ all $count test files live where CI discovers them"
