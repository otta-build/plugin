#!/usr/bin/env bash
# check-pr-body.sh [path]
#
# Verifies .pr-body.md STRUCTURE (the part visible in the body itself):
#   1. a ```acceptance fenced block            (acceptance-block gate)
#   2. a Fixes #<issue> GitHub linkage          (so issue→PR exists in GitHub)
#   3. an idea_ref line                         (so Pulse can join idea→version)
# Test-coverage is a DIFF property, not a body property — see check-test-coverage.sh.
# Exit 0 = body OK. Exit 1 = fix the body first.
set -euo pipefail

BODY="${1:-.pr-body.md}"
if [ ! -f "$BODY" ]; then
  echo "⛔ $BODY missing. Run /otta:start <issue> to create it." >&2
  exit 1
fi

fail=0
note() { echo "  ✗ $1" >&2; fail=1; }

grep -qE '```acceptance' "$BODY" || note "no \`\`\`acceptance fenced block (acceptance-block gate)"

grep -qE '(^|[^A-Za-z])Fixes #[0-9]+' "$BODY" \
  || note "no 'Fixes #<issue>' GitHub linkage — issue→PR link won't exist in GitHub"

# idea_ref must have a real value, not a <!-- comment --> placeholder.
grep -qiE '^idea_ref:\s*[^[:space:]<]' "$BODY" \
  || note "no real 'idea_ref:' value — Pulse can't join idea→version (use issue:#N if unsure)"

# Stale-file guard: if Fixes #N points at an issue that's already CLOSED, this
# .pr-body.md is almost certainly a leftover from a previous, already-merged PR
# (tracked files survive merges) rather than freshly seeded for this change.
# Best-effort only — skip silently if gh is unavailable/unauthenticated/offline.
fixes_issue="$(grep -oE '(^|[^A-Za-z])Fixes #[0-9]+' "$BODY" | grep -oE '[0-9]+' | head -1 || true)"
if [ -n "$fixes_issue" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  issue_state="$(gh issue view "$fixes_issue" --json state -q .state 2>/dev/null || true)"
  if [ "$issue_state" = "CLOSED" ]; then
    note "Fixes #$fixes_issue but issue #$fixes_issue is already CLOSED — $BODY looks stale (leftover from a merged PR). Reseed it: bash scripts/seed-pr-body.sh <issue> --force"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "⛔ otta gate: $BODY incomplete — fix the items above before pushing." >&2
  exit 1
fi
echo "✓ otta gate: $BODY has acceptance block, Fixes #N, idea_ref"
