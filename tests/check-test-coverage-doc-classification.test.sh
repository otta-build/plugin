#!/usr/bin/env bash
# Regression: check-test-coverage.sh must not accept documents as test coverage.
#
# The classifier's third alternative, (^|/)[0-9][0-9][0-9][0-9]-, was added in #68
# while closing #62 — but #62 was about BRANCH-NAME shape (feat/1234-my-feature),
# and the shape rule landed in the test-FILE classifier. Consequence: any path
# segment beginning with four digits and a hyphen counted as test coverage,
# including this plugin's own docs/superpowers/{specs,plans}/YYYY-MM-DD-*.md
# convention. A change shipping a dated design doc alongside untested code passed
# the gate with no test and no [test-impractical:] marker.
#
# Observed live on otta-build/dev#97, cwd and pushed worktree identical — so this
# is NOT the session-cwd resolution bug reported in LC-1140.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/check-test-coverage.sh"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 — expected $2, got $3"; fail=$((fail+1)); fi; }

# Base repo + a feature branch adding the named file(s). No [test-impractical:]
# in the body, so the ONLY thing that can make the gate pass is test classification.
mk_repo_with_files() {
  local d; d="$(mktemp -d)"
  ( cd "$d" || exit 1
    git init -qb main; git config user.email t@t; git config user.name t
    printf 'export const a=1;\n' > base.ts; git add -A; git commit -qm init
    git checkout -qb feat
    printf 'export const a=1;\nexport const b=2;\n' > base.ts   # untested code change
    for f in "$@"; do mkdir -p "$(dirname "$f")"; printf 'placeholder\n' > "$f"; done
    printf '# body with no test-impractical marker\n' > .pr-body.md
    git add -A; git commit -qm change
  ); echo "$d"
}

echo "check-test-coverage — documents are not test coverage:"

# AC1: a dated design doc is not test coverage — this is the reported false-PASS.
R="$(mk_repo_with_files "docs/superpowers/specs/2026-08-02-something-design.md")"
( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC1: dated design doc alone → gate blocks" 1 "$?"

# AC2: same for a dated plan, and for a bare dated doc outside docs/.
R="$(mk_repo_with_files "docs/superpowers/plans/2026-08-02-something.md")"
( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC2a: dated plan doc alone → gate blocks" 1 "$?"
R="$(mk_repo_with_files "docs/2026-08-02-notes.md")"
( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC2b: bare dated doc alone → gate blocks" 1 "$?"

# AC3: markdown never counts, even when the name contains "test".
R="$(mk_repo_with_files "docs/2026-08-02-test-plan.md")"
( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC3: dated doc named *test*.md → gate blocks" 1 "$?"

# AC4: a numeric-prefixed file that is not a test does not count either.
# 0001-init.sql is a migration — it is the change, not proof of the change.
R="$(mk_repo_with_files "packages/db/migrations/0001-init.sql")"
( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC4: numeric-prefixed migration alone → gate blocks" 1 "$?"

# AC5: real test files still count — the fix must not over-tighten.
R="$(mk_repo_with_files "src/thing.test.ts")"
( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC5a: *.test.ts still passes" 0 "$?"
R="$(mk_repo_with_files "tests/thing.sh")"
( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC5b: tests/ dir still passes" 0 "$?"
R="$(mk_repo_with_files "1234-mytest.sh")"
( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC5c: 1234-mytest.sh still passes (preserves #68/#62 intent)" 0 "$?"

# AC6: a doc shipped ALONGSIDE a real test is still fine — the test carries it.
R="$(mk_repo_with_files "docs/superpowers/specs/2026-08-02-x-design.md" "src/thing.test.ts")"
( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 )
check "AC6: doc + real test → gate passes" 0 "$?"

echo "  → $pass passed, $fail failed"
[ "$fail" -eq 0 ]
