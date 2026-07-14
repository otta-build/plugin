#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
PROTOCOL="$REPO/docs/progress-protocol.md"
FIX="$REPO/commands/fix.md"
DEV="$REPO/commands/dev.md"
BUILD="$REPO/commands/build.md"
STATUS="$REPO/commands/status.md"
README="$REPO/README.md"
fail() { echo "✗ $1" >&2; exit 1; }
require() { grep -Eiq "$2" "$1" || fail "$3"; }
reject() { if grep -Eiq "$2" "$1"; then fail "$3"; fi; }

[ -f "$PROTOCOL" ] || fail "missing shared progress protocol"
require "$PROTOCOL" 'read-only.*no.*progress' 'read-only profile must stay silent'
require "$PROTOCOL" 'tiny fix.*Build.*Gate.*PR' 'tiny profile must be Build/Gate/PR'
require "$PROTOCOL" 'interactive delivery.*Seed.*Learn.*Build.*Review.*QA.*Ship' 'interactive stages missing'
require "$PROTOCOL" 'autonomous delivery.*Seed.*Learn.*Build.*Review.*QA.*Ship' 'autonomous stages missing'
require "$PROTOCOL" 'Deploy.*Verify' 'deployment stages missing'
require "$PROTOCOL" 'decision required' 'decision event missing'
require "$PROTOCOL" 'failure or blocker' 'blocker event missing'
require "$PROTOCOL" 'material risk change' 'risk event missing'
require "$PROTOCOL" 'projection.*not.*source of truth|not.*source of truth.*projection' 'truth boundary missing'

require "$FIX" 'Build.*Gate.*PR' 'fix profile missing'
require "$FIX" 'scope expand|eligibility.*no longer|switch to.*otta:(dev|build)' 'fix escalation missing'
require "$DEV" 'Claude Code adapter' 'dev Claude adapter missing'
require "$DEV" 'TaskCreate|TodoCreate|native Task' 'dev must preserve native Tasks'
require "$DEV" 'Codex adapter' 'dev Codex adapter missing'
require "$DEV" 'update_plan|native plan' 'dev Codex plan missing'
require "$DEV" 'meaningful transition' 'dev transition rule missing'
require "$DEV" 'routine narration|redundant narration' 'dev quiet rule missing'
require "$BUILD" 'Workflow.*primary.*progress|primary.*progress.*Workflow' 'build Workflow UI missing'
require "$BUILD" 'second competing|competing checklist|duplicate checklist' 'build duplicate-UI rule missing'
require "$BUILD" 'Codex adapter' 'build Codex adapter missing'
require "$BUILD" 'update_plan|native plan' 'build Codex plan missing'
require "$STATUS" 'resume|resum' 'resumption missing'
require "$STATUS" 'source of truth|durable evidence' 'durable truth missing'
require "$STATUS" 'contradict|conflict' 'conflict rule missing'
require "$README" 'Claude Code.*Task|Task.*Claude Code' 'README Claude UI missing'
require "$README" 'Codex.*plan|plan.*Codex' 'README Codex UI missing'
require "$README" 'QA blocked' 'README blocked example missing'
require "$README" 'Resumed|resume' 'README resumed example missing'
require "$README" 'Completion|completed|shipped' 'README completion example missing'
reject "$DEV" 'while the builder works' 'dev prescribes routine narration'
reject "$BUILD" 'while the builder works' 'build prescribes routine narration'
echo "✓ cross-harness-progress: shared protocol and both adapters are locked"
