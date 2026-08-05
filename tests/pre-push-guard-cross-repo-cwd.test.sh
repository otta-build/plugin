#!/usr/bin/env bash
# pre-push-guard-cross-repo-cwd.test.sh — regression for the cross-repo
# mis-resolution.
#
# pre-push-guard.sh already resolves WHICH repo a push targets (`git -C <path>
# push`, `cd <path> && git push`) and picks that repo's .pr-body.md. But it
# then invoked scripts/otta-gate.sh without entering that repo, so every
# cwd-relative check inside the gate still read the SESSION repo:
#
#   - check-pr-body.sh runs a bare `gh issue view <n>`, and gh infers the repo
#     from the cwd's git remote. Pushing repo B from a session in repo A
#     validated `Fixes #18` against A's issue #18 — a different, unrelated
#     issue that happened to be closed, so the gate reported B's body as
#     "stale, leftover from a merged PR" when B's #18 was open.
#   - check-test-coverage.sh takes no path argument at all; its `git diff
#     origin/HEAD...HEAD` ran in the session repo, so it listed test files
#     from A that were absent from B's diff.
#
# Both symptoms have one cause and one fix: run the gate with cwd set to the
# resolved target repo. This test asserts the invocation is cwd-correct, since
# every current and future cwd-relative sub-check depends on it.
#
# The failure mode is a FALSE BLOCK on legitimate work, and it cannot be worked
# around from inside a session: --no-verify does not apply (this is a PreToolUse
# hook, not a git hook) and an inline `OTTA_SKIP_GATE=1 git push` prefix does not
# reach the hook either, because the hook reads its own environment rather than
# the command string it is passed.
#
# Run: bash tests/pre-push-guard-cross-repo-cwd.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
GUARD="$REPO/hooks/pre-push-guard.sh"
failures=0

fail() { echo "✗ FAIL: $1" >&2; failures=$((failures + 1)); }
pass() { echo "  ✓ $1"; }

[ -f "$GUARD" ] || { fail "missing $GUARD"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Two independent repos, each Otta-governed (.otta.yml) with a .pr-body.md, so
# the guard reaches the gate invocation rather than short-circuiting at line 176.
# `session` is where the agent's shell sits; `target` is what gets pushed.
for name in session target; do
  d="$TMP/$name"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf 'project: %s\n' "$name" > "$d/.otta.yml"
  printf 'body for %s\n\nFixes #1\n' "$name" > "$d/.pr-body.md"
  git -C "$d" add -A
  git -C "$d" -c commit.gpgsign=false commit -qm "init $name"
  # A branch ahead of main, so ahead_of_default() is true (PR-bound work).
  git -C "$d" checkout -q -b feature
  printf 'change\n' > "$d/file.txt"
  git -C "$d" add -A
  git -C "$d" -c commit.gpgsign=false commit -qm "work on $name"
done

# Stub the gate so we can observe the cwd it is invoked with. The guard calls
# "$HERE/../scripts/otta-gate.sh"; shadow that path inside a copy of the plugin
# so the real gate (which shells out to gh) never runs.
PLUGIN="$TMP/plugin"
mkdir -p "$PLUGIN/hooks" "$PLUGIN/scripts"
cp "$GUARD" "$PLUGIN/hooks/pre-push-guard.sh"
cat > "$PLUGIN/scripts/otta-gate.sh" <<'STUB'
#!/usr/bin/env bash
# Records the cwd the guard invoked the gate with, plus the body path argument.
{
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'arg=%s\n' "${1:-}"
} > "$OTTA_TEST_PROBE"
exit 0
STUB
chmod +x "$PLUGIN/scripts/otta-gate.sh"

SESSION="$(cd "$TMP/session" && pwd -P)"
TARGET="$(cd "$TMP/target" && pwd -P)"
PROBE="$TMP/probe"

# Drive the hook exactly as Claude Code does: tool-call JSON on stdin, invoked
# from the SESSION repo, describing a push that targets the OTHER repo.
run_guard() {
  local command_json="$1"
  : > "$PROBE"
  (
    cd "$SESSION" || exit 1
    OTTA_TEST_PROBE="$PROBE" \
      bash "$PLUGIN/hooks/pre-push-guard.sh" \
      <<EOF
{"tool_input":{"command":"$command_json"}}
EOF
  )
}

# Both spellings the header calls out. Each must land the gate in TARGET.
for form in "git -C $TARGET push origin feature" "cd $TARGET && git push origin feature"; do
  run_guard "$form"
  if [ ! -s "$PROBE" ]; then
    fail "gate was never invoked for: $form"
    continue
  fi
  probe_cwd="$(sed -n 's/^cwd=//p' "$PROBE")"
  probe_arg="$(sed -n 's/^arg=//p' "$PROBE")"

  if [ "$probe_cwd" = "$TARGET" ]; then
    pass "gate runs with cwd = target repo for: $form"
  else
    fail "gate ran with cwd=$probe_cwd, expected $TARGET — cwd-relative sub-checks (gh issue view, git diff) will read the wrong repo. Form: $form"
  fi

  # The body path was already correct before the fix; assert it stays correct so
  # a future change can't "fix" the cwd by gating the wrong body.
  if [ "$probe_arg" = "$TARGET/.pr-body.md" ]; then
    pass "gate receives the target repo's .pr-body.md for: $form"
  else
    fail "gate received arg=$probe_arg, expected $TARGET/.pr-body.md. Form: $form"
  fi
done

# Control: a plain push with no redirection must still gate the session repo.
run_guard "git push origin feature"
if [ -s "$PROBE" ] && [ "$(sed -n 's/^cwd=//p' "$PROBE")" = "$SESSION" ]; then
  pass "plain push still gates the session repo"
else
  fail "plain push should gate the session repo, got cwd=$(sed -n 's/^cwd=//p' "$PROBE" 2>/dev/null)"
fi

if [ "$failures" -eq 0 ]; then
  echo "✓ pre-push-guard-cross-repo-cwd: all assertions passed"
  exit 0
fi
echo "✗ pre-push-guard-cross-repo-cwd: $failures failure(s)" >&2
exit 1
