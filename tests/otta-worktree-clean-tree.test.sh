#!/usr/bin/env bash
# Regression: creating a worktree must not modify the target repo's TRACKED files.
#
# Bug: otta-worktree.sh appended '.otta/session.json' to "$WT/.gitignore" on
# every worktree creation. When .gitignore is tracked — the normal case — every
# pipeline run began with a dirty working tree in a file unrelated to the issue
# being worked on. Reviewers correctly stripped it as scope creep (reverted in
# otta-build/pulse#138), so it never landed, and reappeared on the next run.
# A permanent dirt generator.
#
# The intent is right: .otta/session.json is token-adjacent and must never be
# committed. The mechanism must be a repo-local, untracked ignore —
# $GIT_COMMON_DIR/info/exclude — exactly as otta-learning-policy.py already
# does for /.otta/run/ in ensure_local_run_ignore().
# Run: bash tests/otta-worktree-clean-tree.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-worktree.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

# Throwaway origin + clone so `git worktree add` has a real base.
new_repo() { # $1 = dir, $2 = optional pre-existing .gitignore content
  local origin="$TMP/$1-origin.git" work="$TMP/$1"
  git init -q --bare "$origin"
  git clone -q "$origin" "$work" 2>/dev/null
  (
    cd "$work"
    git config user.email t@t.t
    git config user.name t
    # A TRACKED .gitignore — the case the bug corrupts.
    printf 'node_modules/\n%s' "${2:-}" > .gitignore
    git add .gitignore
    git commit -qm init
    git push -q origin HEAD:main
  )
  printf '%s' "$work"
}

# 1. Baseline repo with a tracked .gitignore → worktree creation must leave it
#    pristine.
WORK="$(new_repo plain)"
export OTTA_WORKTREE_DIR="$TMP/wts"
WT="$( cd "$WORK" && bash "$SCRIPT" 501 main 2>/dev/null )"
[ -n "$WT" ] && [ -d "$WT" ] || fail "worktree was not created"

dirty="$( cd "$WT" && git status --porcelain )"
[ -z "$dirty" ] || fail "worktree creation dirtied the tree:
$dirty"

# The source clone must be clean too — the append targeted "$WT/.gitignore",
# but a shared checkout must not pick anything up either.
dirty="$( cd "$WORK" && git status --porcelain )"
[ -z "$dirty" ] || fail "worktree creation dirtied the source repo:
$dirty"

# 2. The ignore must still be in force — this is the whole point of the code.
( cd "$WT" && git check-ignore -q .otta/session.json ) \
  || fail ".otta/session.json is no longer ignored — the fix dropped the protection"

# 3. And it must be enforced by an UNTRACKED mechanism, not by tracked content.
if ( cd "$WT" && git ls-files --error-unmatch .gitignore >/dev/null 2>&1 ); then
  grep -qxF '.otta/session.json' "$WT/.gitignore" 2>/dev/null \
    && fail "the ignore is still written into the tracked .gitignore"
fi

# 4. Idempotent: a second worktree off the same .git stays clean and must not
#    accumulate duplicate exclude lines.
WT2="$( cd "$WORK" && bash "$SCRIPT" 502 main 2>/dev/null )"
[ -n "$WT2" ] && [ -d "$WT2" ] || fail "second worktree was not created"
dirty="$( cd "$WT2" && git status --porcelain )"
[ -z "$dirty" ] || fail "second worktree creation dirtied the tree:
$dirty"

excl="$( cd "$WT2" && git rev-parse --git-path info/exclude )"
if [ -f "$excl" ]; then
  n="$(grep -cxF '.otta/session.json' "$excl" || true)"
  [ "${n:-0}" -le 1 ] || fail "duplicate exclude entries after repeat runs (found $n)"
fi

# 5. A repo that ALREADY carries the line in its tracked .gitignore (installed
#    by an older plugin version) must keep working and must not gain a
#    duplicate or a diff.
WORK2="$(new_repo legacy '.otta/session.json
')"
WT3="$( cd "$WORK2" && bash "$SCRIPT" 503 main 2>/dev/null )"
[ -n "$WT3" ] && [ -d "$WT3" ] || fail "worktree not created in a legacy repo"
dirty="$( cd "$WT3" && git status --porcelain )"
[ -z "$dirty" ] || fail "legacy repo (pre-existing .gitignore line) was dirtied:
$dirty"
n="$(grep -cxF '.otta/session.json' "$WT3/.gitignore" || true)"
[ "${n:-0}" -eq 1 ] || fail "legacy .gitignore line duplicated (found $n)"
( cd "$WT3" && git check-ignore -q .otta/session.json ) \
  || fail "legacy repo lost the ignore"

echo "✓ otta-worktree leaves tracked files clean and still ignores session.json"
