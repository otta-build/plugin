#!/usr/bin/env bash
# Regression test for otta-worktree.sh (#47 worktree isolation).
# Verifies a pipeline run gets an isolated worktree off the base, on its own
# branch, without disturbing the session's current branch — and tears down.
# Run: bash tests/otta-worktree.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-worktree.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

# Build a throwaway repo with a base branch `main` and a dirty feature branch.
REPO="$TMP/repo"
git init -q -b main "$REPO"
cd "$REPO"
git config user.email t@t.t; git config user.name t
echo base > f.txt; git add f.txt; git commit -qm base
git switch -qc feature
echo work >> f.txt; git commit -qam work     # session is on `feature`, ahead of main
SESSION_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

export OTTA_WORKTREE_DIR="$TMP/wt"

# 1. create → prints a path that exists
WT="$(bash "$SCRIPT" 42 main)"
[ -d "$WT" ] || fail "worktree dir not created: $WT"
[ "$WT" = "$TMP/wt/repo-42" ] || fail "unexpected worktree path: $WT"

# 2. worktree is on its own otta/42 branch off main (NOT the feature commit)
WT_BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
[ "$WT_BRANCH" = "otta/42" ] || fail "worktree on wrong branch: $WT_BRANCH"
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git rev-parse main)" ] || fail "worktree not based on main"
grep -q work "$WT/f.txt" && fail "worktree leaked the feature-branch change"

# 3. the session's own branch is untouched
[ "$(git rev-parse --abbrev-ref HEAD)" = "$SESSION_BRANCH" ] || fail "session branch changed to $(git rev-parse --abbrev-ref HEAD)"

# 4. idempotent: second call reuses the same path, no error
WT2="$(bash "$SCRIPT" 42 main)"
[ "$WT2" = "$WT" ] || fail "second call returned different path: $WT2"

# 5. --remove unregisters the worktree but preserves a spawnable cwd tombstone.
#    DevOps invokes removal from inside the worktree, then Codex runs Stop hooks
#    using that recorded path. Deleting the path makes both hooks fail with
#    `No such file or directory (os error 2)` before either hook can start.
( cd "$WT" && bash "$SCRIPT" --remove 42 ) >/dev/null 2>&1 || fail "--remove failed from inside the worktree"
git worktree list --porcelain | grep -Fq "worktree $WT" && fail "worktree still registered after --remove"
[ -d "$WT" ] || fail "removed worktree path is not spawnable for Stop hooks"
( cd "$WT" && pwd >/dev/null ) || fail "cannot start a command from the teardown cwd"
[ ! -e "$WT/.git" ] || fail "teardown cwd still contains a linked worktree"

# 6. A later run for the same issue replaces the empty tombstone with a valid
#    linked worktree instead of treating the directory as reusable state.
WT3="$(bash "$SCRIPT" 42 main)"
[ "$WT3" = "$WT" ] || fail "recreated worktree returned a different path: $WT3"
[ -e "$WT3/.git" ] || fail "teardown tombstone was not replaced with a Git worktree"
[ "$(git -C "$WT3" rev-parse --abbrev-ref HEAD)" = "otta/42" ] || fail "recreated worktree is on the wrong branch"
bash "$SCRIPT" --remove 42 >/dev/null 2>&1 || fail "recreated worktree teardown failed"

# 7. --prune GCs orphans by age: an old worktree is pruned, a fresh one kept.
OLD="$(bash "$SCRIPT" 100 main)"   # simulate a crashed run's leftover
NEW="$(bash "$SCRIPT" 200 main)"   # an in-flight run
touch -t 202001010000 "$OLD" 2>/dev/null || touch -d "2020-01-01" "$OLD"   # backdate the orphan
bash "$SCRIPT" --prune 24 >/dev/null 2>&1 || fail "--prune errored"
[ -d "$OLD" ] && fail "--prune did not remove the aged orphan"
[ -d "$NEW" ] || fail "--prune removed a fresh in-flight worktree"

# --- session link tests ---
TMP_CURL="$(mktemp -d)"
FAKE_CURL="$TMP_CURL/curl"
CURL_LOG="$TMP_CURL/calls.txt"
printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$CURL_LOG" > "$FAKE_CURL"
chmod +x "$FAKE_CURL"

# 7,8,9: CLAUDE_CODE_SESSION_ID set → session.json written + curl called
(
  export CLAUDE_CODE_SESSION_ID="test-session-abc123"
  export OTTA_PULSE_URL="http://localhost:19999"
  export OTTA_PULSE_TOKEN="fake-tok"
  export PATH="${TMP_CURL}:${PATH}"
  bash "$SCRIPT" 8881 main >/dev/null 2>&1 || true
)
WT_8881="$TMP/wt/repo-8881"
[ -f "${WT_8881}/.otta/session.json" ] || fail "7: session.json not written when CLAUDE_CODE_SESSION_ID set"
grep -q "test-session-abc123" "${WT_8881}/.otta/session.json" || fail "8: session.json missing session_id"
grep -q "session-link" "${CURL_LOG}" 2>/dev/null || fail "9: curl not called with session-link"
bash "$SCRIPT" --remove 8881 >/dev/null 2>&1 || true

# 10,11: no CLAUDE_CODE_SESSION_ID → no session.json, no curl
rm -f "$CURL_LOG"
(
  unset CLAUDE_CODE_SESSION_ID
  export OTTA_PULSE_URL="http://localhost:19999"
  export OTTA_PULSE_TOKEN="fake-tok"
  export PATH="${TMP_CURL}:${PATH}"
  bash "$SCRIPT" 8882 main >/dev/null 2>&1 || true
)
WT_8882="$TMP/wt/repo-8882"
[ -d "$WT_8882" ] || fail "10a: worktree 8882 not created (test anchor)"
[ ! -f "${WT_8882}/.otta/session.json" ] || fail "10: session.json created when CLAUDE_CODE_SESSION_ID unset"
[ ! -s "${CURL_LOG}" ] || fail "11: curl called when CLAUDE_CODE_SESSION_ID unset"
bash "$SCRIPT" --remove 8882 >/dev/null 2>&1 || true

rm -rf "$TMP_CURL"

echo "✓ otta-worktree: all 11 checks passed"
