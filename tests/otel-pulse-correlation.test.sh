#!/usr/bin/env bash
# otel-pulse-correlation.test.sh — regression for issue #154 AC(d).
#
# AC(d): OTel correlation attributes are wired for Pulse: setup/telemetry
# docs and the telemetry step emit or document workflow.run_id,
# workflow.name, agent_id, agent_type attribute usage so Pulse can join runs
# to stages.
#
# Run: bash tests/otel-pulse-correlation.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_MD="$HERE/../commands/setup.md"
TELEMETRY_SH="$HERE/../scripts/otta-telemetry-setup.sh"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

[ -f "$SETUP_MD" ]     || fail "setup.md not found at $SETUP_MD"
[ -f "$TELEMETRY_SH" ] || fail "otta-telemetry-setup.sh not found at $TELEMETRY_SH"

for attr in "workflow.run_id" "workflow.name" "agent_id" "agent_type"; do
  grep -qF "$attr" "$SETUP_MD" || fail "setup.md missing correlation attr '$attr'"
done
pass "setup.md documents all 4 Pulse correlation attrs"

for attr in "workflow.run_id" "workflow.name" "agent_id" "agent_type"; do
  grep -qF "$attr" "$TELEMETRY_SH" || fail "otta-telemetry-setup.sh missing correlation attr '$attr'"
done
pass "otta-telemetry-setup.sh documents all 4 Pulse correlation attrs"

grep -qi "join" "$SETUP_MD" || fail "setup.md missing 'join runs to stages' rationale"
pass "setup.md explains the join-to-stages rationale"

echo ""
echo "✓ otel-pulse-correlation: all checks passed"
