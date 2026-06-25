#!/usr/bin/env bash
# subagent-gate-guard.test.sh — behavior test for the SubagentStop gate hook.
# No test framework in this repo; run directly:  bash hooks/subagent-gate-guard.test.sh
# Exits 0 when all cases pass, 1 otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/subagent-gate-guard.sh"
pass=0; fail=0

# Run the guard with a given stdin JSON + env; echo the exit code.
run_guard() { env "$@" bash "$GUARD" >/dev/null 2>&1 <<<"$STDIN"; echo $?; }

check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; pass=$((pass+1));
  else echo "  ✗ $1 — expected exit $2, got $3"; fail=$((fail+1)); fi
}

# A throwaway git repo that is "in the loop" with a gate-PASSING body.
# Includes an origin + origin/HEAD so the gate's base-branch detection works
# (real Otta repos are cloned/worktrees; an origin-less repo is not a real case).
mk_passing_repo() {
  d="$(mktemp -d)"; ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    printf 'x\n' > f.txt; git add -A; git commit -qm init
    git init -q --bare "$d/.origin.git"
    git remote add origin "$d/.origin.git"
    git push -q origin HEAD:main
    git remote set-head origin main
    cat > .pr-body.md <<'EOF'
# t
```acceptance
- [x] does the thing
```
Fixes #1
idea_ref: test
[test-impractical: pure test fixture, no code path]
EOF
  ); echo "$d"
}
# Same, but a body that FAILS the gate (no acceptance block / Fixes / idea_ref).
mk_failing_repo() {
  d="$(mktemp -d)"; ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    printf 'x\n' > f.txt; git add -A; git commit -qm init
    printf '# no markers at all\n' > .pr-body.md
  ); echo "$d"
}

echo "SubagentStop gate guard:"

# 1. Non-builder agent → skip (exit 0), even with a failing repo.
R="$(mk_failing_repo)"; STDIN="$(printf '{"agent_type":"otta:reviewer","cwd":"%s"}' "$R")"
check "non-builder agent_type skips" 0 "$(run_guard)"

# 2. Bypass flag → skip (exit 0).
R="$(mk_failing_repo)"; STDIN="$(printf '{"agent_type":"otta:builder","cwd":"%s"}' "$R")"
check "OTTA_SKIP_GATE=1 bypasses" 0 "$(run_guard OTTA_SKIP_GATE=1)"

# 3. Builder but repo not in the loop (no .pr-body.md) → skip (exit 0).
R="$(mktemp -d)"; ( cd "$R"; git init -q ); STDIN="$(printf '{"agent_type":"otta:builder","cwd":"%s"}' "$R")"
check "no .pr-body.md → skip" 0 "$(run_guard)"

# 4. Builder + in loop + gate PASSES → allow stop (exit 0).
R="$(mk_passing_repo)"; STDIN="$(printf '{"agent_type":"otta:builder","cwd":"%s"}' "$R")"
check "builder + passing gate → exit 0" 0 "$(run_guard OTTA_NO_CAPTURE=1)"

# 5. Builder + in loop + gate FAILS → block the stop (exit 2).
R="$(mk_failing_repo)"; STDIN="$(printf '{"agent_type":"otta:builder","cwd":"%s"}' "$R")"
check "builder + failing gate → exit 2 (block)" 2 "$(run_guard OTTA_NO_CAPTURE=1)"

# 6. Bare "builder" (no namespace) also matches.
R="$(mk_failing_repo)"; STDIN="$(printf '{"agent_type":"builder","cwd":"%s"}' "$R")"
check "bare 'builder' type also gated" 2 "$(run_guard OTTA_NO_CAPTURE=1)"

echo "  → $pass passed, $fail failed"
[ "$fail" -eq 0 ]
