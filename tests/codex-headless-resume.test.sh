#!/usr/bin/env bash
# codex-headless-resume.test.sh — regression for issue #157 AC(g3).
#
# AC(g3): headless Codex guidance (commands/build.md and/or
# commands/schedule.md Codex sections) instructs `codex exec resume
# --output-schema` for structured stage verdicts when resuming headless
# runs, gated on availability.
#
# Run: bash tests/codex-headless-resume.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_MD="$HERE/../commands/build.md"
SCHEDULE_MD="$HERE/../commands/schedule.md"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

[ -f "$BUILD_MD" ]    || fail "build.md not found at $BUILD_MD"
[ -f "$SCHEDULE_MD" ] || fail "schedule.md not found at $SCHEDULE_MD"

found_in() {
  local needle="$1"
  grep -qF -- "$needle" "$BUILD_MD" || grep -qF -- "$needle" "$SCHEDULE_MD"
}

found_in 'codex exec resume' || fail "no Codex adapter section documents 'codex exec resume'"
pass "a Codex adapter section documents codex exec resume"

found_in '--output-schema' || fail "no Codex adapter section documents --output-schema"
pass "a Codex adapter section documents --output-schema"

found_in 'structured' || fail "no Codex adapter section ties --output-schema to structured stage verdicts"
pass "a Codex adapter section ties --output-schema to structured stage verdicts"

found_in 'where available' || found_in 'when available' || found_in 'on Codex versions without' \
  || fail "no Codex adapter section gates --output-schema on availability"
pass "--output-schema guidance is availability-gated"

echo ""
echo "✓ codex-headless-resume: all checks passed"
