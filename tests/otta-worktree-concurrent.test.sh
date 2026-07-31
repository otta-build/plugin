#!/usr/bin/env bash
# Regression: N concurrent otta-worktree.sh calls must all succeed (no
# "fatal: could not lock" race on the shared .git/worktrees).
# Run: bash tests/otta-worktree-concurrent.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-worktree.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

# Build a throwaway origin + local clone so `git worktree add` has a real base.
ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN"
WORK="$TMP/work"
git clone -q "$ORIGIN" "$WORK"
cd "$WORK"
git config user.email t@t.t; git config user.name t
git commit -q --allow-empty -m init
git push -q origin HEAD:main

export OTTA_WORKTREE_DIR="$TMP/wts"

# Fire 6 concurrent worktree creations for distinct issues off the same .git.
pids=""
for n in 1 2 3 4 5 6; do
  ( cd "$WORK" && bash "$SCRIPT" "$n" main >/dev/null 2>"$TMP/err-$n" ) &
  pids="$pids $!"
done
ok=0
for p in $pids; do if wait "$p"; then ok=$((ok + 1)); fi; done

[ "$ok" = "6" ] || { cat "$TMP"/err-* >&2; fail "only $ok/6 concurrent worktree creates succeeded"; }

# How many worktree dirs exist for issue $1?
#
# This used to be `[ -e "$TMP/wts"/*"-$n/.git" ]`, which is SC2144: the glob
# expands BEFORE `[` runs, so the behaviour depended on the match count —
#   1 match  → correct (the only case that ever occurred, hence unnoticed)
#   2+       → `[: ...: binary operator expected`, and the assertion returns
#              FALSE — a worktree that exists is reported missing, behind a
#              cryptic bash error
#   0        → correct by accident (glob stays literal, -e false)
# Counting matches explicitly is correct for all three, and this is the
# concurrency test, which is exactly where 2+ is plausible.
worktree_count_for() {
  local n="$1" m
  shopt -s nullglob
  m=( "$TMP/wts"/*"-$n"/.git )
  shopt -u nullglob
  printf '%s' "${#m[@]}"
}

for n in 1 2 3 4 5 6; do
  c="$(worktree_count_for "$n")"
  [ "$c" = "1" ] || fail "expected exactly 1 worktree for issue $n, found $c"
done

# Regression cases for the counting itself — the 2+ branch is the one the old
# construct got wrong, so assert it is now detected rather than crashing.
mkdir -p "$TMP/wts/decoy-1/.git"
c="$(worktree_count_for 1)"
[ "$c" = "2" ] || fail "multi-match detection broken: expected 2, got $c"
rm -rf "$TMP/wts/decoy-1"

c="$(worktree_count_for 1)"
[ "$c" = "1" ] || fail "count did not return to 1 after removing the decoy, got $c"

c="$(worktree_count_for 99)"
[ "$c" = "0" ] || fail "no-match detection broken: expected 0, got $c"
grep -rq 'could not lock' "$TMP"/err-* && fail "git worktree lock race still occurs"

echo "✓ otta-worktree concurrent: 6/6 created, no lock race"
