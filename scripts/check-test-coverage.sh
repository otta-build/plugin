#!/usr/bin/env bash
# check-test-coverage.sh [base-ref] [body-path]
#
# Accurate local mirror of the test-coverage gate: the change must either ADD a
# test file in the diff, OR carry an explicit [test-impractical: <reason>] in
# the PR body. Mirrors CI exactly by reading the real diff, not a body line.
# base-ref defaults to the merge-base with origin's default branch.
set -euo pipefail

BASE="${1:-}"
BODY="${2:-.pr-body.md}"
TAG="[otta-gate:test-coverage]"

if [ -z "$BASE" ]; then
  # Default branch from origin/HEAD when present. The trailing `|| true` keeps
  # `set -e` from aborting when there is NO origin/HEAD — a fresh clone or a
  # local-only repo (common for any team's first run), where the symbolic-ref
  # pipeline fails. Fall back to the local default branch, then the root commit.
  DEFAULT="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
  DEFAULT="${DEFAULT:-main}"
  if git rev-parse --verify -q "origin/$DEFAULT" >/dev/null 2>&1; then
    BASE="$(git merge-base "origin/$DEFAULT" HEAD 2>/dev/null || echo "origin/$DEFAULT")"
  elif git rev-parse --verify -q "$DEFAULT" >/dev/null 2>&1 && [ "$(git rev-parse "$DEFAULT")" != "$(git rev-parse HEAD)" ]; then
    BASE="$(git merge-base "$DEFAULT" HEAD 2>/dev/null || echo "$DEFAULT")"
  else
    BASE="$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)"
  fi
fi

# No changes at all between base and HEAD → nothing to gate yet. Don't emit a
# coverage failure for an empty diff (e.g. a fresh worktree before the first edit).
if [ -z "$(git diff --name-only "$BASE"...HEAD 2>/dev/null)" ]; then
  echo "✓ $TAG no changes to gate yet (empty $BASE...HEAD diff)."
  exit 0
fi

# Added/modified test files in the diff (broad: *.test.* / *.spec.* / tests/ dir).
TEST_FILES="$(git diff --name-only "$BASE"...HEAD 2>/dev/null \
  | grep -iE '(\.(test|spec)\.[a-z]+$|(^|/)tests?/|(^|/)[0-9][0-9][0-9][0-9]-)' || true)"

if [ -n "$TEST_FILES" ]; then
  echo "✓ $TAG diff adds/edits test file(s):"
  echo "$TEST_FILES" | sed 's/^/    /'
  exit 0
fi

if [ -f "$BODY" ] && grep -qiE '\[test-impractical:' "$BODY"; then
  echo "✓ $TAG no test in diff, but [test-impractical: …] declared in $BODY"
  exit 0
fi

echo "⛔ $TAG diff adds no test file and $BODY has no [test-impractical: <reason>]." >&2
echo "   Add a focused test, or justify with [test-impractical: <reason>] in the PR body." >&2
exit 1
