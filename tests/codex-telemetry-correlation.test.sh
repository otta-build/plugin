#!/usr/bin/env bash
# codex-telemetry-correlation.test.sh — regression for issue #157 AC(g2, g6).
#
# AC(g2): scripts/otta-codex-setup.sh and/or commands/setup.md's Codex
# telemetry step document SubagentStart/SubagentStop hook events, subagent
# identity in hook inputs, and parent session-ID inheritance (Codex
# v0.131-0.134) so Pulse can join pipeline stages to sessions.
#
# AC(g6): the same Codex telemetry surface documents that Codex >=0.141
# emits seconds-based OTEL duration histograms, and that
# `hide_spawn_agent_metadata` defaults true (v0.137) — noted in the Codex
# adapter debugging guidance.
#
# Run: bash tests/codex-telemetry-correlation.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_MD="$HERE/../commands/setup.md"
CODEX_SETUP_SH="$HERE/../scripts/otta-codex-setup.sh"
DEV_MD="$HERE/../commands/dev.md"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

[ -f "$SETUP_MD" ]       || fail "setup.md not found at $SETUP_MD"
[ -f "$CODEX_SETUP_SH" ] || fail "otta-codex-setup.sh not found at $CODEX_SETUP_SH"

# The telemetry surface is either setup.md or otta-codex-setup.sh (or both).
found_in() {
  local needle="$1"
  grep -qF "$needle" "$SETUP_MD" || grep -qF "$needle" "$CODEX_SETUP_SH"
}

found_in 'SubagentStart' || fail "Codex telemetry surface missing SubagentStart reference"
pass "Codex telemetry surface documents SubagentStart"

found_in 'SubagentStop' || fail "Codex telemetry surface missing SubagentStop reference"
pass "Codex telemetry surface documents SubagentStop"

found_in 'subagent identity' || fail "Codex telemetry surface missing subagent identity reference"
pass "Codex telemetry surface documents subagent identity in hook inputs"

found_in 'session ID' || fail "Codex telemetry surface missing parent session-ID inheritance reference"
pass "Codex telemetry surface documents parent session-ID inheritance as the Pulse join key"

found_in 'seconds' || fail "Codex telemetry surface missing seconds-based OTEL histogram note"
pass "Codex telemetry surface notes seconds-based OTEL duration histograms"

grep -qF 'hide_spawn_agent_metadata' "$CODEX_SETUP_SH" || grep -qF 'hide_spawn_agent_metadata' "$DEV_MD" \
  || fail "hide_spawn_agent_metadata default not documented in Codex telemetry/debugging surface"
pass "Codex adapter debugging guidance notes the hide_spawn_agent_metadata default"

echo ""
echo "✓ codex-telemetry-correlation: all checks passed"
