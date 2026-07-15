#!/usr/bin/env bash
# hooks-shell-injection-guard.test.sh — regression for issue #154 AC(c2).
#
# (c2) was originally rescoped because hooks/hooks.json was read by BOTH the
# Claude Code and Codex plugin manifests, and the CC hook schema's exec
# `args` array form and shell-string `command` form are mutually exclusive
# — migrating to `args` in place would have broken Codex's `bash -c
# "$command"` execution (see tests/codex-plugin-parity.test.sh). Issue #155
# shipped the harness split: hooks/hooks.codex.json (Codex, shell form) and
# hooks/hooks.claude.json (Claude Code, exec args form) — see
# tests/hooks-harness-split.test.sh.
#
# What's in scope here: the injection-hardening rationale itself. CC
# 2.1.207 rejects `${user_config.*}` interpolation in shell-form hook
# commands. This is the falsifiable, auditable guard for that — the Codex
# hooks file must stay clean of that pattern regardless of which form it
# uses.
#
# Run: bash tests/hooks-shell-injection-guard.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HERE/../hooks/hooks.codex.json"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

[ -f "$HOOKS" ] || fail "hooks.codex.json not found at $HOOKS"

if grep -F '${user_config.' "$HOOKS" >/dev/null 2>&1; then
  fail "hooks.codex.json contains \${user_config.*} interpolation in a hook command — rejected by CC 2.1.207"
fi
pass "hooks.codex.json contains no \${user_config.*} interpolation (audit clean)"

echo ""
echo "✓ hooks-shell-injection-guard: all checks passed"
