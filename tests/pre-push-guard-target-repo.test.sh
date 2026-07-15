#!/usr/bin/env bash
# Regression test for issue #159: pre-push-guard.sh resolves the toplevel from
# the session CWD via `git rev-parse --show-toplevel`, so a push that targets a
# DIFFERENT repo (`git -C <other> push`, or `cd <other> && git push`) is gated
# against the SESSION repo instead of the repo actually being pushed. A stale
# .pr-body.md in the session repo then falsely blocks unrelated pushes.
# Run: bash plugins/otta/tests/pre-push-guard-target-repo.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../hooks/pre-push-guard.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail() { echo "✗ $1" >&2; exit 1; }

# A .pr-body.md that reliably FAILS otta-gate.sh (no source diff for
# check-test-coverage.sh), so we can tell whether the gate ran against it.
failing_body() {
  cat <<'EOF'
## Summary
- stale

```acceptance
GIVEN x
WHEN y
THEN z
- [x] AC1: done
```

idea_ref: issue:#99

Fixes #99
EOF
}

# GATED: the session repo, has a .pr-body.md that would fail the gate.
GATED="$TMPDIR/gated"
mkdir -p "$GATED"
(cd "$GATED" && git init -q)
failing_body > "$GATED/.pr-body.md"

# OTHER: a completely separate repo with no .pr-body.md at all.
OTHER="$TMPDIR/other"
mkdir -p "$OTHER"
(cd "$OTHER" && git init -q)

# 1. `git -C <OTHER> push` from within GATED's cwd must NOT be gated against
#    GATED's stale/failing .pr-body.md — the hook must exit 0 without running
#    the gate at all.
rc1=0
out1="$(cd "$GATED" && printf '%s' "{\"tool_input\":{\"command\":\"git -C $OTHER push origin main\"}}" | bash "$GUARD" 2>&1)" || rc1=$?
[ "$rc1" -eq 0 ] || fail "expected exit 0 for 'git -C <other> push' from gated cwd, got $rc1: $out1"
printf '%s' "$out1" | grep -q "otta-gate" && fail "gate must not run for a push targeting a different repo, but it did: $out1"

# 2. `cd <OTHER> && git push` (compound command) from within GATED's cwd must
#    also NOT be gated against GATED's stale/failing .pr-body.md.
rc2=0
out2="$(cd "$GATED" && printf '%s' "{\"tool_input\":{\"command\":\"cd $OTHER && git push origin main\"}}" | bash "$GUARD" 2>&1)" || rc2=$?
[ "$rc2" -eq 0 ] || fail "expected exit 0 for 'cd <other> && git push' from gated cwd, got $rc2: $out2"
printf '%s' "$out2" | grep -q "otta-gate" && fail "gate must not run for a compound 'cd <other> && git push', but it did: $out2"

# 3. A plain `git push` (no -C, no cd) from within GATED's cwd must still be
#    gated exactly as before — the gate runs and blocks on the failing body.
rc3=0
out3="$(cd "$GATED" && printf '%s' '{"tool_input":{"command":"git push origin main"}}' | bash "$GUARD" 2>&1)" || rc3=$?
[ "$rc3" -eq 2 ] || fail "expected exit 2 (blocked) for plain 'git push' targeting the gated repo, got $rc3: $out3"
printf '%s' "$out3" | grep -q "otta gate blocked this push" || fail "expected gate-blocked message for plain push targeting gated repo: $out3"

# 4. `git -C <GATED> push` from within OTHER's cwd (no .pr-body.md there) must
#    explicitly target GATED and be gated/blocked.
rc4=0
out4="$(cd "$OTHER" && printf '%s' "{\"tool_input\":{\"command\":\"git -C $GATED push origin main\"}}" | bash "$GUARD" 2>&1)" || rc4=$?
[ "$rc4" -eq 2 ] || fail "expected exit 2 (blocked) for 'git -C <gated> push' from other cwd, got $rc4: $out4"

# 5. `(git push)` (subshell-wrapped, trailing `)` directly after `push`, no
#    whitespace) from within GATED's cwd must still be detected as a push
#    targeting the gated repo and gated/blocked — not silently ignored.
rc5=0
out5="$(cd "$GATED" && printf '%s' '{"tool_input":{"command":"(git push)"}}' | bash "$GUARD" 2>&1)" || rc5=$?
[ "$rc5" -eq 2 ] || fail "expected exit 2 (blocked) for '(git push)' targeting the gated repo, got $rc5: $out5"

# 6. `git push&` (trailing `&`, no whitespace) from within GATED's cwd must
#    also still be detected and gated/blocked.
rc6=0
out6="$(cd "$GATED" && printf '%s' '{"tool_input":{"command":"git push&"}}' | bash "$GUARD" 2>&1)" || rc6=$?
[ "$rc6" -eq 2 ] || fail "expected exit 2 (blocked) for 'git push&' targeting the gated repo, got $rc6: $out6"

# 7. `(cd <OTHER> && git push)` (subshell-wrapped compound cd+push) from
#    within GATED's cwd must scope to OTHER, same as the unwrapped form.
rc7=0
out7="$(cd "$GATED" && printf '%s' "{\"tool_input\":{\"command\":\"(cd $OTHER && git push origin main)\"}}" | bash "$GUARD" 2>&1)" || rc7=$?
[ "$rc7" -eq 0 ] || fail "expected exit 0 for '(cd <other> && git push)' from gated cwd, got $rc7: $out7"
printf '%s' "$out7" | grep -q "otta-gate" && fail "gate must not run for a subshell-wrapped 'cd <other> && git push', but it did: $out7"

echo "✓ pre-push-guard-target-repo: all 7 checks passed"
