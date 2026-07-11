#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$HERE/../workflows/otta-build.mjs"
fail() { echo "FAIL: $1" >&2; exit 1; }

grep -q "import { decideRepair, normalizeMaxRevisions } from './repair-policy.mjs'" "$WORKFLOW" || fail "workflow must import shared repair policy"
grep -q 'const decision = decideRepair' "$WORKFLOW" || fail "workflow must execute shared repair decision"
grep -q 'decision.action ===.*stop' "$WORKFLOW" || fail "workflow must handle stop decision"
grep -q 'otta-repair-loop.sh.*emit.*outcome stalled' "$WORKFLOW" || fail "terminal stop must emit stalled evidence"
grep -q 'schema: EVIDENCE_SCHEMA' "$WORKFLOW" || fail "terminal emit must return structured evidence"
grep -q '!evidence.emitted' "$WORKFLOW" || fail "workflow must fail closed when evidence is not verified"
grep -q 'reason: decision.reason' "$WORKFLOW" || fail "blocked result must preserve policy reason"

echo "build-repair-policy: shared policy and terminal evidence wiring pass"
