#!/usr/bin/env bash
# Regression: check-test-coverage.sh must use [0-9][0-9][0-9][0-9]- to recognise
# numeric-prefix test files, not ????- (which would also match letter-prefixes
# like "skip-"). AC1: skip-something.sh NOT a test. AC2: 1234-mytest.sh IS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/check-test-coverage.sh"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 — expected $2, got $3"; fail=$((fail+1)); fi; }

# Helper: init a base repo with one commit, create a branch, add a file, commit.
mk_repo_with_file() {
  local fname="$1"
  local d
  d="$(mktemp -d)"
  ( cd "$d"
    git init -qb main; git config user.email t@t; git config user.name t
    printf 'export const a=1;\n' > base.ts; git add -A; git commit -qm init
    git checkout -qb feat
    printf 'placeholder\n' > "$fname"
    git add -A; git commit -qm "add $fname"
  )
  echo "$d"
}

echo "otta-gate-glob — numeric-prefix GLOB filter:"

# AC1: skip-something.sh in diff → NOT treated as a test file → gate exits 1
R="$(mk_repo_with_file "skip-something.sh")"
( cd "$R"; printf '# no-test body\n' > .pr-body.md; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC1: skip-something.sh is NOT a test file (gate blocks)" 1 "$?"

# AC2: 1234-mytest.sh in diff → IS treated as a test file → gate exits 0
R="$(mk_repo_with_file "1234-mytest.sh")"
( cd "$R"; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC2: 1234-mytest.sh IS a test file (gate passes)" 0 "$?"

echo "  → $pass passed, $fail failed"
[ "$fail" -eq 0 ]
