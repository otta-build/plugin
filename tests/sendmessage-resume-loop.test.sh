#!/usr/bin/env bash
# sendmessage-resume-loop.test.sh — regression for issue #154 AC(b).
#
# AC(b): /otta:dev's fix-loop for Claude Code resumes the existing named
# builder via SendMessage({to: <builder name>}) with reviewer feedback,
# instead of spawning a fresh builder. The Codex send_message path is
# unchanged. Agent names passed to SendMessage must be valid
# (^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ — no '#').
#
# Run: bash tests/sendmessage-resume-loop.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_MD="$HERE/../commands/dev.md"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

[ -f "$DEV_MD" ] || fail "dev.md not found at $DEV_MD"

grep -q "SendMessage" "$DEV_MD" || fail "dev.md missing SendMessage reference"
pass "dev.md references SendMessage"

grep -qiE "resum(e|ing)" "$DEV_MD" || fail "dev.md missing 'resume' instruction for the fix loop"
pass "dev.md instructs resuming (not respawning) the builder"

grep -qE 'SendMessage\(\{[[:space:]]*to:' "$DEV_MD" \
  || fail "dev.md missing SendMessage({to: ...}) call form"
pass "dev.md shows the SendMessage({to: ...}) call form"

# Codex path (send_message) must remain documented and untouched.
grep -q "send_message" "$DEV_MD" || fail "dev.md lost the Codex send_message path"
pass "dev.md retains the Codex send_message path"

# No agent name passed to a Task/Agent/SendMessage dispatch may contain '#'
# (invalid per ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ — breaks SendMessage resume).
if grep -oE '(name: *"[^"]*"|to: *"[^"]*")' "$DEV_MD" | grep -q '#'; then
  fail "dev.md still passes a '#'-containing agent name (invalid for SendMessage/name matching)"
fi
pass "dev.md agent names contain no '#' (valid ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\$)"

echo ""
echo "✓ sendmessage-resume-loop: all checks passed"
