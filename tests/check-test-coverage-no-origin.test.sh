#!/usr/bin/env bash
# Regression: check-test-coverage.sh must not crash on a repo with no origin/HEAD
# (fresh clone / local-only repo — any team's first run). Found by the fresh-repo
# onboarding test 2026-06-25: the BASE-detection pipeline aborted under `set -e`.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/check-test-coverage.sh"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 — expected $2, got $3"; fail=$((fail+1)); fi; }

# A local-only repo (NO origin) on a feature branch with a test-bearing change.
mk_no_origin_repo() {
  d="$(mktemp -d)"; ( cd "$d" || exit 1
    git init -qb main; git config user.email t@t; git config user.name t
    printf 'export const a=1;\n' > a.ts; git add -A; git commit -qm init
    git checkout -qb feat
    printf 'export const a=1;\nexport const b=2;\n' > a.ts
    printf 'test("b",()=>{});\n' > a.test.ts
    git add -A; git commit -qm change
  ); echo "$d"
}

echo "check-test-coverage — no origin/HEAD:"

# 1. Change WITH a test → exit 0 (detects the test), does NOT crash on missing origin.
R="$(mk_no_origin_repo)"; ( cd "$R" || exit 1; bash "$SCRIPT" >/dev/null 2>&1 ); check "no-origin + test in diff → pass (no crash)" 0 "$?"

# 2. Change WITHOUT a test and no [test-impractical] → clean exit 1 (not a crash/137).
R="$(mk_no_origin_repo)"; ( cd "$R" || exit 1; rm a.test.ts; git commit -qam "drop test"; printf '# x\n' > .pr-body.md; bash "$SCRIPT" >/dev/null 2>&1 ); check "no-origin + no test → clean fail (exit 1)" 1 "$?"

# 3. Empty diff (HEAD vs HEAD) → "no changes to gate yet" exit 0.
R="$(mk_no_origin_repo)"; ( cd "$R" || exit 1; bash "$SCRIPT" HEAD >/dev/null 2>&1 ); check "explicit empty diff → exit 0" 0 "$?"

echo "  → $pass passed, $fail failed"
[ "$fail" -eq 0 ]
