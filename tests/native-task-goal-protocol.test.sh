#!/usr/bin/env bash
# native-task-goal-protocol.test.sh — regression for issue #154 AC(a).
#
# AC(a): /otta:start and /otta:dev define a first-class native task protocol:
# on start, create one task per pipeline stage via TaskCreate and update
# status via TaskUpdate on stage transitions; set the session goal from the
# issue's acceptance criteria via /goal where available. Markdown checklist
# remains the documented fallback when task tools are unavailable.
#
# Run: bash tests/native-task-goal-protocol.test.sh
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

  grep -q "TaskCreate" "$f" || fail "$name missing TaskCreate reference"
  pass "$name references TaskCreate"

  grep -q "TaskUpdate" "$f" || fail "$name missing TaskUpdate reference"
  pass "$name references TaskUpdate"

  grep -qE '/goal|`goal`' "$f" || fail "$name missing /goal reference"
  pass "$name references /goal"

  grep -qiE "markdown checklist|checklist.*fallback|fallback.*checklist" "$f" \
    || fail "$name missing markdown-checklist fallback instruction"
  pass "$name documents markdown checklist fallback"
done

# The task protocol must name the four pipeline stages so one task per stage
# can actually be created.
for stage in build spec-review verify ship; do
  grep -qi "$stage" "$START_MD" || fail "start.md missing pipeline stage '$stage'"
done
pass "start.md names all four pipeline stages (build, spec-review, verify, ship)"

echo ""
echo "✓ native-task-goal-protocol: all checks passed"
