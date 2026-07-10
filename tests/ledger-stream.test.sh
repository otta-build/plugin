#!/usr/bin/env bash
# ledger-stream.test.sh — tests for issue #5: zero-paste Pulse wiring.
# Verifies: local jsonl back-compat, /ledger POST best-effort (non-fatal),
# OTTA_NO_CAPTURE suppression, and .otta/pulse.env env-var precedence.
# Run: bash tests/ledger-stream.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/ledger-append.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

COMMON_ARGS='--source gate --event gate_run --score 1 --feedback ok --project test/repo'

# Allocate per-run unique base port using this script's PID.
# Ports are spread by 100 to avoid overlap even if adjacent PIDs are used.
_base=$(( (($$ % 1000) * 3) + 20000 ))
_P3=$(( _base ))
_P4=$(( _base + 100 ))
_P5=$(( _base + 200 ))

# Helper: start a one-shot nc listener on a port; write pid to $2, log to $3.
# `nc -l` relays bidirectionally; if stdin hits EOF immediately (non-interactive
# run), nc can close the connection before writing the inbound request to $logfile.
# Feed stdin from a long-lived `sleep` to prevent that race.
# Use a 200 ms fixed sleep instead of lsof polling to avoid lsof hanging on macOS
# (lsof -iTCP can stall under certain file-system conditions).
nc_listen() {
  local port="$1" pidfile="$2" logfile="$3"
  (sleep 30 | nc -l "$port" >"$logfile" 2>/dev/null) &
  echo $! >"$pidfile"
  sleep 0.2   # 200 ms: enough for nc to bind on loopback; fixed to avoid lsof stalls
}
nc_stop() {
  local pidfile="$1"
  local pid
  pid="$(cat "$pidfile" 2>/dev/null || echo '')"
  [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
}

# ── Test 1 ────────────────────────────────────────────────────────────────────
# No Pulse vars → local jsonl written, exits 0.
LEDGER="$TMP/t1"; mkdir -p "$LEDGER"
OTTA_LEDGER_DIR="$LEDGER" bash "$SCRIPT" $COMMON_ARGS >/dev/null 2>&1
[ -f "$LEDGER/test-repo.jsonl" ] || fail "test 1: local jsonl not created without Pulse vars"
pass "no Pulse vars → local jsonl written, exit 0"

# ── Test 2 ────────────────────────────────────────────────────────────────────
# Bogus OTTA_PULSE_URL + token → exits 0 (non-fatal) AND local jsonl written.
LEDGER="$TMP/t2"; mkdir -p "$LEDGER"
OTTA_LEDGER_DIR="$LEDGER" OTTA_PULSE_URL="http://127.0.0.1:1" OTTA_PULSE_TOKEN="dummy-token" \
  bash "$SCRIPT" $COMMON_ARGS >/dev/null 2>&1 \
  || fail "test 2: unreachable Pulse URL made script exit non-zero"
[ -f "$LEDGER/test-repo.jsonl" ] || fail "test 2: local jsonl not written when Pulse push fails"
pass "bogus Pulse URL → exit 0, local jsonl still written"

# ── Test 3 ────────────────────────────────────────────────────────────────────
# OTTA_NO_CAPTURE=1 → /ledger POST suppressed; script still exits 0 and writes locally.
LEDGER="$TMP/t3"; mkdir -p "$LEDGER"
NC_PORT=$_P3; PIDFILE="$TMP/nc3.pid"; NC_LOG="$TMP/nc3.log"
nc_listen "$NC_PORT" "$PIDFILE" "$NC_LOG"
(OTTA_LEDGER_DIR="$LEDGER" OTTA_PULSE_URL="http://127.0.0.1:$NC_PORT" \
 OTTA_PULSE_TOKEN="t" OTTA_NO_CAPTURE=1 \
 bash "$SCRIPT" $COMMON_ARGS >/dev/null 2>&1) \
 || fail "test 3: OTTA_NO_CAPTURE=1 made script exit non-zero"
sleep 0.3
nc_stop "$PIDFILE"
if [ -s "$NC_LOG" ]; then
  fail "test 3: OTTA_NO_CAPTURE=1 did not suppress the /ledger POST"
fi
[ -f "$LEDGER/test-repo.jsonl" ] || fail "test 3: local jsonl not written with OTTA_NO_CAPTURE=1"
pass "OTTA_NO_CAPTURE=1 → POST suppressed, exit 0, local jsonl written"

# ── Test 4 ────────────────────────────────────────────────────────────────────
# .otta/pulse.env is sourced: vars from file trigger /ledger POST attempt.
REPO_DIR="$TMP/repo4"; mkdir -p "$REPO_DIR/.otta"
LEDGER="$TMP/t4"; mkdir -p "$LEDGER"
NC_PORT=$_P4; PIDFILE="$TMP/nc4.pid"; NC_LOG="$TMP/nc4.log"
printf 'OTTA_PULSE_URL=http://127.0.0.1:%s\nOTTA_PULSE_TOKEN=from-file\n' "$NC_PORT" \
  > "$REPO_DIR/.otta/pulse.env"
nc_listen "$NC_PORT" "$PIDFILE" "$NC_LOG"
# Unset Pulse vars so the script reads them solely from .otta/pulse.env;
# without this, an OTTA_PULSE_URL already exported in the developer's shell
# would override the file and bypass the local nc listener.
(cd "$REPO_DIR" && unset OTTA_PULSE_URL OTTA_PULSE_TOKEN OTTA_NO_CAPTURE && \
  OTTA_LEDGER_DIR="$LEDGER" bash "$SCRIPT" $COMMON_ARGS >/dev/null 2>&1) \
  || fail "test 4: env-file sourcing made script exit non-zero"
# Poll for the POST to land; nc flushes immediately on receipt so the first
# 100 ms check should succeed when the POST fired.
tries=0
while [ ! -s "$NC_LOG" ] && [ "$tries" -lt 30 ]; do
  tries=$((tries + 1))
  sleep 0.1
done
nc_stop "$PIDFILE"
[ -f "$LEDGER/test-repo.jsonl" ] || fail "test 4: local jsonl not written"
[ -s "$NC_LOG" ] || fail "test 4: .otta/pulse.env not sourced (no /ledger POST attempt detected)"
pass ".otta/pulse.env sourced → /ledger POST attempted, exit 0, local jsonl written"

# ── Test 5 ────────────────────────────────────────────────────────────────────
# Explicit env var wins over .otta/pulse.env.
REPO_DIR="$TMP/repo5"; mkdir -p "$REPO_DIR/.otta"
LEDGER="$TMP/t5"; mkdir -p "$LEDGER"
NC_PORT=$_P5; PIDFILE="$TMP/nc5.pid"; NC_LOG="$TMP/nc5.log"
printf 'OTTA_PULSE_URL=http://127.0.0.1:%s\nOTTA_PULSE_TOKEN=from-file\n' "$NC_PORT" \
  > "$REPO_DIR/.otta/pulse.env"
nc_listen "$NC_PORT" "$PIDFILE" "$NC_LOG"
(cd "$REPO_DIR" && OTTA_LEDGER_DIR="$LEDGER" OTTA_PULSE_TOKEN="" \
  bash "$SCRIPT" $COMMON_ARGS >/dev/null 2>&1) \
  || fail "test 5: env override made script exit non-zero"
sleep 0.3
nc_stop "$PIDFILE"
[ -f "$LEDGER/test-repo.jsonl" ] || fail "test 5: local jsonl not written"
if [ -s "$NC_LOG" ]; then
  fail "test 5: empty OTTA_PULSE_TOKEN in env did not beat .otta/pulse.env (POST still fired)"
fi
pass "explicit empty env token beats .otta/pulse.env → no POST, exit 0"

echo ""
echo "✓ ledger-stream: all 5 checks passed"
