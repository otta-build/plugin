#!/usr/bin/env bash
# otta-gate.sh — run the full local Otta gate (body structure + test-coverage).
# Mirrors the Otta Pulse merge gates so failures surface BEFORE push, not in CI.
# Exit 0 = ready to push. Non-zero = blocked.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok=0
bash "$HERE/check-pr-body.sh" "${1:-.pr-body.md}" || ok=1
bash "$HERE/check-test-coverage.sh" || ok=1

if [ "$ok" -ne 0 ]; then
  echo "" >&2
  echo "⛔ otta gate failed — fix the above before pushing (or you'll fail CI)." >&2
  exit 1
fi
echo "✓ otta gate passed — clear to push."
