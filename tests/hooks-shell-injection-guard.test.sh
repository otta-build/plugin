#!/usr/bin/env bash
# hooks-shell-injection-guard.test.sh — regression for issue #154 AC(c2), rescoped.
#
# (c2) was rescoped after discovering hooks/hooks.json is read by BOTH the
# Claude Code and Codex plugin manifests, and the CC hook schema's exec
# `args` array form and shell-string `command` form are mutually exclusive
# — migrating to `args` would force `command` down to a bare executable
# name, breaking Codex's `bash -c "$command"` execution (see
# tests/codex-plugin-parity.test.sh). The harness-split migration needed to
# do this safely is deferred to issue #155.
#
# What's in scope for #154: the injection-hardening rationale itself. CC
# 2.1.207 rejects `${user_config.*}` interpolation in shell-form hook
# commands. This is the falsifiable, auditable guard for that — hooks.json
# must stay clean of that pattern regardless of which form it uses.
#
# Run: bash tests/hooks-shell-injection-guard.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HERE/../hooks/hooks.json"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

[ -f "$HOOKS" ] || fail "hooks.json not found at $HOOKS"

if grep -F '${user_config.' "$HOOKS" >/dev/null 2>&1; then
  fail "hooks.json contains \${user_config.*} interpolation in a hook command — rejected by CC 2.1.207"
fi
pass "hooks.json contains no \${user_config.*} interpolation (audit clean)"

echo ""
echo "✓ hooks-shell-injection-guard: all checks passed"
