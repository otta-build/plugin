#!/usr/bin/env bash
# check-ac-layers.sh [path]
#
# Enforces AC layer tag rules in .pr-body.md:
#   [ui-layer] / [e2e]   — require preview URL or e2e evidence, NOT unit tests alone
#   [data-layer]         — unit tests sufficient, no UI required
#
# Layer key (canonical):
#   [data-layer] — schema + mutations + unit tests, no UI required
#   [ui-layer]   — requires working page/component visible in the app
#   [e2e]        — requires full user flow: link → action → observable result
#
# Exit 0 = OK (may print warnings for AC3). Exit 1 = gate violation (AC1).
set -euo pipefail

BODY="${1:-.pr-body.md}"
TAG="[otta-gate:ac-layers]"
[ -f "$BODY" ] || { echo "✓ $TAG no $BODY found, skipping layer check"; exit 0; }

fail=0

# Returns 0 (true) if evidence string looks like unit-test-only output:
# has test keyword AND has no URL / preview / e2e / screenshot keyword.
_is_unit_only() {
  local ev="$1"
  [ -z "$ev" ] && return 1
  # Has URL or e2e-specific keyword → NOT unit-only
  echo "$ev" | grep -qiE '(https?://|localhost|preview|screenshot|playwright|cypress|e2e)' && return 1
  # Has a test keyword → unit-only evidence
  echo "$ev" | grep -qiE '(test|unit|npm[[:space:]]+run|jest|vitest|spec)' && return 0
  return 1
}

# AC1: checked [ui-layer]/[e2e] ACs with unit-test-only evidence → fail.
while IFS= read -r line; do
  # Only checked items: - [x]
  echo "$line" | grep -qiE '^\s*-\s*\[x\]' || continue
  # Has [ui-layer] or [e2e] as the LEADING tag (immediately after ACN), not in prose
  echo "$line" | grep -qiE '^[-*]\s+\[[xX]\]\s+AC[0-9]+[^[]*\[(ui-layer|e2e)\]' || continue
  # Extract evidence: text after the last em-dash (—)
  echo "$line" | grep -qF "—" || continue
  evidence="$(echo "$line" | sed 's/.*—//')"
  if _is_unit_only "$evidence"; then
    echo "⛔ $TAG AC tagged [ui-layer]/[e2e] requires preview URL or e2e evidence — unit test insufficient." >&2
    echo "   Failing AC: $line" >&2
    fail=1
  fi
done < "$BODY"

# AC3: warn (exit 0) when there are unclosed [ui-layer]/[e2e] ACs
# and the only closed ACs are [data-layer] ones.
UNCLOSED_UI="$(grep -iE '^\s*-\s*\[ \]\s+AC[0-9]+[^[]*\[(ui-layer|e2e)\]' "$BODY" || true)"
CLOSED_DATA="$(grep -iE '^\s*-\s*\[x\]\s+AC[0-9]+[^[]*\[data-layer\]' "$BODY" || true)"
CLOSED_UI="$(grep -iE '^\s*-\s*\[x\]\s+AC[0-9]+[^[]*\[(ui-layer|e2e)\]' "$BODY" || true)"

if [ -n "$UNCLOSED_UI" ] && [ -n "$CLOSED_DATA" ] && [ -z "$CLOSED_UI" ]; then
  echo "⚠ $TAG Issue has unclosed [ui-layer]/[e2e] ACs — issue will remain open after merge." >&2
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "✓ $TAG layer tag evidence checks passed."
