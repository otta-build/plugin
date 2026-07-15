#!/usr/bin/env bash
# codex-goal-protocol.test.sh — regression for issue #157 AC(g1).
#
# AC(g1): Codex adapter sections of commands/start.md and commands/dev.md
# instruct using Codex's persisted goal system (/goal) where available —
# goal set from the issue's acceptance criteria at pipeline start —
# alongside the existing update_plan protocol, with explicit fallback to
# update_plan-only on Codex versions lacking goals.
#
# Run: bash tests/codex-goal-protocol.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_MD="$HERE/../commands/start.md"
DEV_MD="$HERE/../commands/dev.md"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

[ -f "$START_MD" ] || fail "start.md not found at $START_MD"
[ -f "$DEV_MD" ]   || fail "dev.md not found at $DEV_MD"

for f in "$START_MD" "$DEV_MD"; do
  name="$(basename "$f")"

  grep -qF 'Codex' "$f" || fail "$name missing a Codex-specific reference"
  pass "$name mentions Codex"

  grep -qF 'persisted' "$f" && grep -qE '/goal|`goal`' "$f" \
    || fail "$name missing reference to Codex's persisted goal system"
  pass "$name references Codex's persisted goal system"

  grep -qF "issue's acceptance criteria" "$f" \
    || fail "$name missing 'set from the issue's acceptance criteria' instruction"
  pass "$name sets the goal from the issue's acceptance criteria"

  grep -qF 'update_plan' "$f" \
    || fail "$name missing update_plan protocol reference"
  pass "$name keeps the update_plan protocol"

  grep -qE 'fall back to `?update_plan`? only|update_plan.only' "$f" \
    || fail "$name missing explicit fallback to update_plan-only"
  pass "$name documents explicit fallback to update_plan-only"
done

echo ""
echo "✓ codex-goal-protocol: all checks passed"
