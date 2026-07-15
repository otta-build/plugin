#!/usr/bin/env bash
# codex-delegation-approval.test.sh — regression for issue #157 AC(g4).
#
# AC(g4): setup/AGENTS.md Codex guidance recommends explicit multi-agent
# delegation control (explicit-request-only) for pipeline runs so stages
# don't self-delegate, and documents the `writes` approval mode as the
# recommended CI/headless setting (Codex v0.142/v0.144).
#
# Run: bash tests/codex-delegation-approval.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_MD="$HERE/../commands/setup.md"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

[ -f "$SETUP_MD" ] || fail "setup.md not found at $SETUP_MD"

grep -qF 'explicit-request-only' "$SETUP_MD" \
  || fail "setup.md missing explicit-request-only delegation recommendation"
pass "setup.md recommends explicit-request-only multi-agent delegation"

grep -qiE 'self-delegat' "$SETUP_MD" \
  || fail "setup.md does not explain why explicit-request-only is recommended (self-delegation)"
pass "setup.md explains the self-delegation rationale"

grep -qF '`writes`' "$SETUP_MD" || grep -qF "'writes'" "$SETUP_MD" \
  || fail "setup.md missing writes approval mode recommendation"
pass "setup.md documents the writes approval mode"

grep -qiE 'CI|headless' "$SETUP_MD" \
  || fail "setup.md does not tie the writes approval mode to CI/headless runs"
pass "setup.md ties writes approval mode to CI/headless runs"

echo ""
echo "✓ codex-delegation-approval: all checks passed"
