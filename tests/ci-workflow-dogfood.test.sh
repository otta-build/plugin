#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/ci.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq 'pull_request:' "$WORKFLOW" || fail "PR CI trigger was removed"
grep -Fq 'push:' "$WORKFLOW" || fail "push CI trigger was removed"
grep -Fq 'workflow_dispatch:' "$WORKFLOW" || fail "manual CI trigger is missing"
grep -Fq 'otta_sha:' "$WORKFLOW" || fail "manual CI lacks the Otta SHA input"
grep -Fq 'run-name:' "$WORKFLOW" || fail "CI lacks an explicit run title"
grep -Fq 'inputs.otta_sha' "$WORKFLOW" || fail "run title does not expose the Otta SHA input"

echo "ci-workflow-dogfood: PASS"
