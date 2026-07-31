#!/usr/bin/env bash
# Regression test for the fail-OPEN hole at pre-push-guard.sh:129.
#
# Bug: the guard ended with `[ -f "$TOPLEVEL/.pr-body.md" ] || exit 0`. While
# .pr-body.md was a tracked file it was never absent, so the hole was masked.
# Once the file is untracked+gitignored (otta-build/dev#78), a branch with no
# seeded body pushes with NO gate at all — the gate silently does nothing,
# which is worse than the stale-body failure it replaced.
#
# Fix: in an Otta-governed repo (marked by .otta.yml, the same opt-in marker
# otta-deploy-readiness.sh:93 uses), a push from a branch that is ahead of the
# default branch must fail CLOSED when .pr-body.md is missing.
#
# Non-Otta repos must be untouched: this is a global PreToolUse hook, so
# blocking every feature-branch push everywhere would be a severe regression.
# Run: bash plugins/otta/tests/pre-push-guard-missing-body.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../hooks/pre-push-guard.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail() { echo "✗ $1" >&2; exit 1; }

# Build a repo with a `main` default branch and one commit on it.
make_repo() {
  local dir="$1" governed="$2"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    echo seed > seed.txt
    git add seed.txt
    git commit -qm "seed"
    # Must not be the subshell's last command as a bare `[ ] &&` — under
    # `set -e` the false branch would abort the whole test run silently.
    if [ "$governed" = "governed" ]; then
      printf 'base: main\n' > .otta.yml
    fi
  )
}

# Move onto a feature branch with a commit not on main.
branch_ahead() {
  (
    cd "$1"
    git switch -qc feature
    echo work > work.txt
    git add work.txt
    git commit -qm "work"
  )
}

run_guard() {
  # Emits the PreToolUse tool-call JSON the hook reads on stdin.
  local dir="$1"
  ( cd "$dir" && printf '{"tool_input":{"command":"git push"}}' | bash "$GUARD" >/dev/null 2>&1 )
}

# 1. Otta-governed repo, branch ahead of main, NO .pr-body.md → must fail closed.
G="$TMPDIR/governed"
make_repo "$G" governed
branch_ahead "$G"
rc=0; run_guard "$G" || rc=$?
[ "$rc" -eq 2 ] || fail "governed repo, branch ahead, no .pr-body.md: expected exit 2 (fail closed), got $rc"

# 2. Non-Otta repo (no .otta.yml), same shape → must stay silent (exit 0).
#    This is the false-positive guard: the hook is global.
U="$TMPDIR/ungoverned"
make_repo "$U" plain
branch_ahead "$U"
rc=0; run_guard "$U" || rc=$?
[ "$rc" -eq 0 ] || fail "ungoverned repo must not be gated: expected exit 0, got $rc"

# 3. Otta-governed repo sitting on the default branch with nothing ahead →
#    not PR-bound, nothing to gate, exit 0.
D="$TMPDIR/on-default"
make_repo "$D" governed
rc=0; run_guard "$D" || rc=$?
[ "$rc" -eq 0 ] || fail "governed repo on default branch: expected exit 0, got $rc"

# 4. OTTA_SKIP_GATE=1 still bypasses, even in the newly-blocking case.
rc=0
( cd "$G" && printf '{"tool_input":{"command":"git push"}}' | OTTA_SKIP_GATE=1 bash "$GUARD" >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 0 ] || fail "OTTA_SKIP_GATE=1 must bypass: expected exit 0, got $rc"

# 5. A non-push command in the newly-blocking repo is still silently ignored.
rc=0
( cd "$G" && printf '{"tool_input":{"command":"git status"}}' | bash "$GUARD" >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 0 ] || fail "non-push command must be ignored: expected exit 0, got $rc"

# 6. The block message must name the cause, not just fail cryptically.
msg="$( cd "$G" && printf '{"tool_input":{"command":"git push"}}' | bash "$GUARD" 2>&1 >/dev/null || true )"
printf '%s' "$msg" | grep -qi "pr-body" \
  || fail "block message must mention .pr-body.md; got: $msg"

echo "✓ pre-push-guard fails closed on a missing .pr-body.md in Otta-governed repos only"
