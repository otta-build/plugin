#!/usr/bin/env bash
# Regression test for issue #160: deterministic-cost mode for autonomous runs.
# Claude Code's advisor tool is inherited by every subagent and re-reads the
# full transcript per call (uncached) — a nondeterministic cost/latency
# multiplier when nobody is watching. Scheduled/cloud routines and headless
# `/otta:build -p` runs must set CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 in their
# Claude Code launch env; interactive `/otta:dev` must not.
# Run: bash plugins/otta/tests/advisor-autonomous-runs.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEDULE_MD="$HERE/../commands/schedule.md"
BUILD_MD="$HERE/../commands/build.md"
DEV_MD="$HERE/../commands/dev.md"

fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$SCHEDULE_MD" ] || fail "schedule.md not found at $SCHEDULE_MD"
[ -f "$BUILD_MD" ] || fail "build.md not found at $BUILD_MD"
[ -f "$DEV_MD" ] || fail "dev.md not found at $DEV_MD"

# 1. schedule.md sets the env var in the Claude Code launch guidance.
grep -q "CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1" "$SCHEDULE_MD" \
  || fail "schedule.md does not set CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1"

# 2. build.md documents the same recommendation for headless/unattended runs.
grep -q "CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1" "$BUILD_MD" \
  || fail "build.md does not set CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1"

# 3. build.md is explicit this does NOT apply to interactive /otta:dev.
grep -qi "otta:dev" "$BUILD_MD" \
  || fail "build.md does not explicitly exclude /otta:dev from the advisor-off recommendation"

# 4. Interactive dev.md is unchanged: no advisor-off env var set there.
grep -q "CLAUDE_CODE_DISABLE_ADVISOR_TOOL" "$DEV_MD" \
  && fail "dev.md must not set CLAUDE_CODE_DISABLE_ADVISOR_TOOL — interactive /otta:dev keeps the advisor available"

echo "✓ advisor-autonomous-runs: all 4 checks passed"
