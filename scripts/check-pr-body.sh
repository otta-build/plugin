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
TAG="[otta-gate:pr-body]"
if [ ! -f "$BODY" ]; then
  echo "⛔ $TAG $BODY missing. Run /otta:start <issue> to create it." >&2
  exit 1
fi

fail=0
note() { echo "  ⛔ $TAG $1" >&2; fail=1; }

grep -qE '```acceptance' "$BODY" || note "no \`\`\`acceptance fenced block (acceptance-block gate)"

grep -qE '(^|[^A-Za-z])Fixes #[0-9]+' "$BODY" \
  || note "no 'Fixes #<issue>' GitHub linkage — issue→PR link won't exist in GitHub"

# idea_ref must have a real value, not a <!-- comment --> placeholder.
grep -qiE '^idea_ref:\s*[^[:space:]<]' "$BODY" \
  || note "no real 'idea_ref:' value — Pulse can't join idea→version (use issue:#N if unsure)"

# Stale-file guard. Two tiers, because the cheap one is also the stronger one.
fixes_issue="$(grep -oE '(^|[^A-Za-z])Fixes #[0-9]+' "$BODY" | grep -oE '[0-9]+' | head -1 || true)"

if [ -n "${OTTA_EXPECTED_ISSUE:-}" ]; then
  # Tier 1 — the caller told us which issue this run is for (/otta:dev exports
  # it). Comparing that to the body's own Fixes #N settles staleness locally:
  # no network, no gh auth, and it catches a leftover body whose issue is still
  # OPEN, which the CLOSED-state check below can never see.
  expected="${OTTA_EXPECTED_ISSUE#\#}"
  if [ -z "$fixes_issue" ]; then
    note "no 'Fixes #<issue>' to compare against expected issue #$expected"
  elif [ "$fixes_issue" != "$expected" ]; then
    note "$BODY is for issue #$fixes_issue but this run is for issue #$expected — wrong/stale body. Reseed it: bash scripts/seed-pr-body.sh $expected --force"
  fi
elif [ -n "$fixes_issue" ]; then
  # Tier 2 — no expected issue supplied, so fall back to asking GitHub whether
  # the linked issue is already CLOSED (a body left over from a merged PR).
  # This one needs the network, so its absence is REPORTED rather than swallowed:
  # a check that silently did not run must not read as a check that passed.
  if ! command -v gh >/dev/null 2>&1; then
    echo "  ℹ $TAG stale-issue check SKIPPED (gh not installed) — staleness unverified. Set OTTA_EXPECTED_ISSUE=<n> for an offline check." >&2
  elif ! gh auth status >/dev/null 2>&1; then
    echo "  ℹ $TAG stale-issue check SKIPPED (gh not authenticated) — staleness unverified. Set OTTA_EXPECTED_ISSUE=<n> for an offline check." >&2
  elif ! issue_state="$(gh issue view "$fixes_issue" --json state -q .state 2>/dev/null)"; then
    echo "  ℹ $TAG stale-issue check SKIPPED (could not read issue #$fixes_issue) — staleness unverified." >&2
  elif [ "$issue_state" = "CLOSED" ]; then
    note "Fixes #$fixes_issue but issue #$fixes_issue is already CLOSED — $BODY looks stale (leftover from a merged PR). Reseed it: bash scripts/seed-pr-body.sh <issue> --force"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "⛔ $TAG $BODY incomplete — fix the items above before pushing." >&2
  exit 1
fi
echo "✓ $TAG $BODY has acceptance block, Fixes #N, idea_ref"
