#!/usr/bin/env bash
# otta-gate.sh — run the full local Otta gate (body structure + test-coverage + AC layers).
# Mirrors the Otta Pulse merge gates so failures surface BEFORE push, not in CI.
# Exit 0 = ready to push. Non-zero = blocked.
#
# AC layer key (enforced by check-ac-layers.sh):
#   [data-layer] — schema + mutations + unit tests, no UI required
#   [ui-layer]   — requires working page/component visible in the app
#   [e2e]        — requires full user flow: link → action → observable result
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'HELP'
otta-gate.sh [path-to-pr-body.md]

Runs the full local Otta gate before push. Mirrors CI merge gates.
Checks: body structure · test coverage · AC layer tag evidence.

AC layer key:
  [data-layer] — schema + mutations + unit tests, no UI required
  [ui-layer]   — requires working page/component visible in the app
  [e2e]        — requires full user flow: link → action → observable result

[ui-layer] and [e2e] ACs must be verified with a preview URL, screenshot, or
e2e tool evidence. A unit test alone is insufficient evidence for these layers.
HELP
  exit 0
fi

ok=0
reasons=""
out="$(bash "$HERE/check-pr-body.sh" "${1:-.pr-body.md}" 2>&1)" || { ok=1; reasons="$out"; }
[ -z "${OTTA_GATE_QUIET:-}" ] && printf '%s\n' "$out"
out="$(bash "$HERE/check-test-coverage.sh" 2>&1)" || { ok=1; reasons="${reasons}
${out}"; }
[ -z "${OTTA_GATE_QUIET:-}" ] && printf '%s\n' "$out"
out="$(bash "$HERE/check-ac-layers.sh" "${1:-.pr-body.md}" 2>&1)" || { ok=1; reasons="${reasons}
${out}"; }
[ -z "${OTTA_GATE_QUIET:-}" ] && printf '%s\n' "$out"

# Route the verdict through the resolved per-run LEARN policy. Disabled capture
# writes only a metadata skip receipt; it never writes the verdict to the ledger.
# Capture failure remains non-blocking for the deterministic gate result.
fb="$([ "$ok" -eq 0 ] && echo "all gates passed" || printf '%s' "$reasons" | tr '\n' ' ' | sed 's/  */ /g')"
bash "$HERE/otta-learning-policy.sh" capture --source gate --event gate_run \
  --score "$([ "$ok" -eq 0 ] && echo 1 || echo 0)" --feedback "$fb" \
  --input "{\"branch\":\"$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')\"}" \
  >/dev/null 2>&1 || true

if [ "$ok" -ne 0 ]; then
  echo "" >&2
  echo "⛔ [otta-gate] failed — fix the above before pushing (or you'll fail CI)." >&2
  exit 1
fi
echo "✓ [otta-gate] passed — clear to push."
