#!/usr/bin/env bash
# pipeline-checklist.test.sh — structural regression for issue #105
# (pipeline stage checklist UX in /otta:dev, /otta:build, /otta:status, README).
#
# AC1: dev.md + build.md instruct orchestrator to create a stage checklist at run start
# AC2: stage failures annotate the checklist item with the failure reason
# AC3: /otta:status renders the stage list for in-flight issues
# AC4: zero new deps — harness native task/todo; graceful degradation (markdown fallback)
# AC5: README pipeline section shows the checklist UX
#
# Run: bash tests/pipeline-checklist.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_MD="$HERE/../commands/dev.md"
BUILD_MD="$HERE/../commands/build.md"
STATUS_MD="$HERE/../commands/status.md"
README="$HERE/../README.md"

fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$DEV_MD" ]    || fail "dev.md not found at $DEV_MD"
[ -f "$BUILD_MD" ]  || fail "build.md not found at $BUILD_MD"
[ -f "$STATUS_MD" ] || fail "status.md not found at $STATUS_MD"
[ -f "$README" ]    || fail "README.md not found at $README"

# ---------------------------------------------------------------------------
# AC1(dev): dev.md instructs creating a checklist at run start with stage names
# ---------------------------------------------------------------------------
grep -qi "checklist" "$DEV_MD" \
  || fail "AC1: dev.md missing 'checklist' instruction"

# Key stage names — each must appear in dev.md.
grep -qi "seed"   "$DEV_MD" || fail "AC1: dev.md missing stage 'seed'"
grep -qi "learn"  "$DEV_MD" || fail "AC1: dev.md missing stage 'learn'"
grep -qi "build"  "$DEV_MD" || fail "AC1: dev.md missing stage 'build'"
grep -qiE "spec.review|spec-review|spec review" "$DEV_MD" || fail "AC1: dev.md missing stage 'spec-review'"
grep -qiE "qa|verify" "$DEV_MD" || fail "AC1: dev.md missing stage 'qa/verify'"
grep -qi "ship"   "$DEV_MD" || fail "AC1: dev.md missing stage 'ship'"
grep -qi "deploy" "$DEV_MD" || fail "AC1: dev.md missing stage 'deploy'"

# ---------------------------------------------------------------------------
# AC1(build): build.md instructs creating a checklist at run start
# ---------------------------------------------------------------------------
grep -qi "checklist" "$BUILD_MD" \
  || fail "AC1: build.md missing 'checklist' instruction"

# ---------------------------------------------------------------------------
# AC2: stage failures annotate the item with failure reason
# ---------------------------------------------------------------------------
# The instruction should mention annotating/marking failures with a reason.
grep -qiE "failure.*reason|annotate.*fail|mark.*fail|blocked.*why|blocked and why" "$DEV_MD" \
  || fail "AC2: dev.md missing instruction to annotate failures with reason"

# ---------------------------------------------------------------------------
# AC3: /otta:status renders the stage checklist (in-flight runs)
# ---------------------------------------------------------------------------
grep -qiE "stage checklist|pipeline stage|checklist.*stage|in-flight|in.flight" "$STATUS_MD" \
  || fail "AC3: status.md missing instruction to render pipeline stage checklist"

# ---------------------------------------------------------------------------
# AC4: harness-native task/todo mechanism; graceful degradation
# ---------------------------------------------------------------------------
grep -qiE "TaskCreate|TodoCreate|native task|task tool|todo tool" "$DEV_MD" \
  || fail "AC4: dev.md missing reference to native task/todo tool"
grep -qiE "degrad|fallback|markdown.*checklist|checklist.*markdown|no native|no.*task.*tool|without.*task" "$DEV_MD" \
  || fail "AC4: dev.md missing graceful degradation (markdown fallback)"

# AC4: activeForm updated per stage transition (agent switcher UX).
grep -qi "activeForm" "$DEV_MD" \
  || fail "AC4: dev.md missing activeForm update instruction (agent switcher stage column)"

# ---------------------------------------------------------------------------
# AC5: README has a pipeline checklist section
# ---------------------------------------------------------------------------
grep -qiE "stage checklist|pipeline.*checklist|checklist.*UX|checklist.*pipeline" "$README" \
  || fail "AC5: README missing pipeline stage checklist section"

echo "✓ pipeline-checklist: all AC1–AC5 checks passed"
