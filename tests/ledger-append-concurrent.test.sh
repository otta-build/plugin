#!/usr/bin/env bash
# Regression: N concurrent appends of fat (>4KB) records to the shared per-repo
# ledger must yield N intact JSON lines (no O_APPEND interleave past PIPE_BUF).
# Run: bash tests/ledger-append-concurrent.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/ledger-append.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

BIG="$(head -c 6000 < /dev/zero | tr '\0' 'x')"   # 6KB payload, exceeds PIPE_BUF
N=16
pids=""
for i in $(seq "$N"); do
  ( OTTA_LEDGER_DIR="$TMP" OTTA_NO_CAPTURE=1 bash "$SCRIPT" \
      --source gate --event gate_run --score 1 \
      --feedback "$BIG-$i" --project "acme/web" >/dev/null 2>&1 ) &
  pids="$pids $!"
done
for p in $pids; do wait "$p"; done

F="$TMP/acme-web.jsonl"
[ "$(wc -l < "$F" | tr -d ' ')" = "$N" ] || fail "expected $N lines, got $(wc -l < "$F")"
# every line must be valid JSON (interleave would break parsing)
bad=0
while IFS= read -r line; do
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad=$((bad + 1))
done < "$F"
[ "$bad" = "0" ] || fail "$bad corrupted (interleaved) JSON lines"

echo "✓ ledger-append concurrent: $N intact lines, no interleave"
