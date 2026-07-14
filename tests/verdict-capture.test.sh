#!/usr/bin/env bash
# Regression test: reviewer + qa agents must capture their LLM verdict to the
# LEARN ledger (richer GEPA signal than the deterministic gate alone).
# Guards against the capture step being dropped from the agent prompts.
# Run: bash tests/verdict-capture.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS="$HERE/../agents"
fail() { echo "✗ $1" >&2; exit 1; }

# 1. reviewer captures a spec_review verdict through the resolved policy
grep -q 'otta-learning-policy.sh.*capture' "$AGENTS/reviewer.md" || fail "reviewer.md missing policy-aware capture"
grep -q -- '--source reviewer' "$AGENTS/reviewer.md" || fail "reviewer.md capture missing --source reviewer"
grep -q -- '--event spec_review' "$AGENTS/reviewer.md" || fail "reviewer.md capture missing --event spec_review"

# 2. qa captures a verify verdict through the resolved policy
grep -q 'otta-learning-policy.sh.*capture' "$AGENTS/qa.md" || fail "qa.md missing policy-aware capture"
grep -q -- '--source qa' "$AGENTS/qa.md" || fail "qa.md capture missing --source qa"
grep -q -- '--event verify' "$AGENTS/qa.md" || fail "qa.md capture missing --event verify"

# 3. both use the portable root precedence (Codex skill state → hook root → Claude root)
PORTABLE_POLICY='${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-learning-policy.sh'
grep -Fq "$PORTABLE_POLICY" "$AGENTS/reviewer.md" || fail "reviewer.md not using portable plugin root path"
grep -Fq "$PORTABLE_POLICY" "$AGENTS/qa.md" || fail "qa.md not using portable plugin root path"

echo "✓ verdict-capture: all checks passed"
