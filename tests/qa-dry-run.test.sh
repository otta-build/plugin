#!/usr/bin/env bash
# Regression test: qa agent must instruct real-sample dry-run for heuristic ACs.
# Lesson from #58: green tests on a synthetic fixture missed real-data failures.
# Guards against the instruction being dropped from qa.md.
# Run: bash tests/qa-dry-run.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA="$HERE/../agents/qa.md"
fail() { echo "✗ $1" >&2; exit 1; }

# AC1: qa.md instructs running code on a real project sample, not only the author's fixture.
grep -qi 'real sample\|real-world' "$QA" || fail "qa.md missing real-sample instruction (AC1)"
grep -qi 'fixture' "$QA" || fail "qa.md does not contrast real sample against author's fixture (AC1)"

# AC2: the instruction is scoped to heuristic/classifier/parser ACs (not pure-logic ACs).
grep -qi 'heuristic\|classifier\|parser' "$QA" || fail "qa.md missing scope qualifier (heuristic/classifier/parser) (AC2)"

# AC3: the dry-run output must be included in the verdict for the human to judge.
grep -qi 'dry.run' "$QA" || fail "qa.md missing dry-run mention (AC3)"
grep -qi 'verdict' "$QA" || fail "qa.md missing verdict mention (AC3)"

echo "✓ qa-dry-run: all checks passed"
