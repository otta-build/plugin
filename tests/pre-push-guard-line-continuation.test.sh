#!/usr/bin/env bash
# Regression test for issue #161: pre-push-guard.sh splits the command on
# newlines when building segments, so a shell backslash line-continuation —
# `git \` + newline + `push origin main` — puts `git` on one line and `push`
# on the next. No single segment matches both `git` and `push`, so
# push_segments_seen stays 0 and the hook exits 0 without ever gating a real
# push. Fix: collapse backslash-newline continuations into a single line
# before segment parsing. Also covers the CRLF variant (`git \` + CR + LF +
# `push`), which a naive `\<LF>`-only collapse misses (the backslash is
# immediately followed by CR, not LF).
# Run: bash plugins/otta/tests/pre-push-guard-line-continuation.test.sh
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

# 1. `git \` + newline + `push origin main` — the continuation form of a
#    plain push — must still be detected and gated/blocked, not silently
#    let through as push_segments_seen=0.
rc1=0
out1="$(cd "$GATED" && printf '%s' '{"tool_input":{"command":"git \\\npush origin main"}}' | bash "$GUARD" 2>&1)" || rc1=$?
[ "$rc1" -eq 2 ] || fail "expected exit 2 (blocked) for 'git \\<newline>push origin main', got $rc1: $out1"
printf '%s' "$out1" | grep -q "otta gate blocked this push" || fail "expected gate-blocked message for continuation push: $out1"

# 2. `git push \` + newline + `--force` — continuation after `push` itself —
#    must also still be detected and gated/blocked.
rc2=0
out2="$(cd "$GATED" && printf '%s' '{"tool_input":{"command":"git push \\\n--force"}}' | bash "$GUARD" 2>&1)" || rc2=$?
[ "$rc2" -eq 2 ] || fail "expected exit 2 (blocked) for 'git push \\<newline>--force', got $rc2: $out2"
printf '%s' "$out2" | grep -q "otta gate blocked this push" || fail "expected gate-blocked message for continuation push --force: $out2"

# 3. `git \` + CRLF (carriage return + newline) + `push origin main` — the
#    CRLF variant of the continuation form (e.g. a command typed/pasted with
#    Windows-style line endings) — must also be detected and gated/blocked.
rc3=0
out3="$(cd "$GATED" && printf '%s' '{"tool_input":{"command":"git \\\r\npush origin main"}}' | bash "$GUARD" 2>&1)" || rc3=$?
[ "$rc3" -eq 2 ] || fail "expected exit 2 (blocked) for 'git \\<CRLF>push origin main', got $rc3: $out3"
printf '%s' "$out3" | grep -q "otta gate blocked this push" || fail "expected gate-blocked message for CRLF continuation push: $out3"

echo "✓ pre-push-guard-line-continuation: all 3 checks passed"
