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
for n in 1 2 3 4 5 6; do
  [ -e "$TMP/wts"/*"-$n/.git" ] || fail "worktree for issue $n missing"
done
grep -rq 'could not lock' "$TMP"/err-* && fail "git worktree lock race still occurs"

echo "✓ otta-worktree concurrent: 6/6 created, no lock race"
