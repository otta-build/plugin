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

# Helper: start a one-shot nc listener on a port; write pid to $1, log to $2.
# Returns 0 if nc bound, 1 if unavailable (caller should skip).
# `nc -l` relays bidirectionally (stdin -> socket, socket -> stdout); if its
# stdin hits EOF immediately (as it does when inherited from a non-interactive
# test run), nc can race its own shutdown and close the connection before it
# has finished writing the inbound request to $logfile. Feed it stdin from a
# long-lived `sleep` so it only ever shuts down because the peer (curl)
# closed the connection, never because of its own stdin EOF.
nc_listen() {
  local port="$1" pidfile="$2" logfile="$3"
  (sleep 30 | nc -l "$port" >"$logfile" 2>/dev/null) &
  echo $! >"$pidfile"
  # Poll until nc has actually bound the port instead of a fixed sleep,
  # which is a race under load (curl can fire before nc binds).
  # Prefer lsof (checks LISTEN state without opening a connection, so it
  # can't itself consume the listener's one-shot connection); fall back to
  # `nc -z` (a connect probe) only when lsof is unavailable.
  local tries=0
  while true; do
    if command -v lsof >/dev/null 2>&1; then
      lsof -iTCP:"$port" -sTCP:LISTEN -n -P >/dev/null 2>&1 && break
    else
      nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && break
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      return 1
    fi
    sleep 0.1
  done
  return 0
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
# Use a local listener to detect whether a connection was made.
LEDGER="$TMP/t3"; mkdir -p "$LEDGER"
NC_PORT=19873; PIDFILE="$TMP/nc3.pid"; NC_LOG="$TMP/nc3.log"
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
NC_PORT=19874; PIDFILE="$TMP/nc4.pid"; NC_LOG="$TMP/nc4.log"
printf 'OTTA_PULSE_URL=http://127.0.0.1:%s\nOTTA_PULSE_TOKEN=from-file\n' "$NC_PORT" \
  > "$REPO_DIR/.otta/pulse.env"
nc_listen "$NC_PORT" "$PIDFILE" "$NC_LOG"
(cd "$REPO_DIR" && OTTA_LEDGER_DIR="$LEDGER" bash "$SCRIPT" $COMMON_ARGS >/dev/null 2>&1) \
  || fail "test 4: env-file sourcing made script exit non-zero"
# Poll for the POST to land instead of a fixed sleep: curl -m 3 may take a
# moment, and nc only flushes its output once it has something to flush.
tries=0
while [ ! -s "$NC_LOG" ] && [ "$tries" -lt 20 ]; do
  tries=$((tries + 1))
  sleep 0.1
done
nc_stop "$PIDFILE"
[ -f "$LEDGER/test-repo.jsonl" ] || fail "test 4: local jsonl not written"
[ -s "$NC_LOG" ] || fail "test 4: .otta/pulse.env not sourced (no /ledger POST attempt detected)"
pass ".otta/pulse.env sourced → /ledger POST attempted, exit 0, local jsonl written"

# ── Test 5 ────────────────────────────────────────────────────────────────────
# Explicit env var wins over .otta/pulse.env.
# File has a valid listener URL + token; env exports empty OTTA_PULSE_TOKEN →
# both vars must be non-empty for POST to fire, so no POST should happen.
REPO_DIR="$TMP/repo5"; mkdir -p "$REPO_DIR/.otta"
LEDGER="$TMP/t5"; mkdir -p "$LEDGER"
NC_PORT=19875; PIDFILE="$TMP/nc5.pid"; NC_LOG="$TMP/nc5.log"
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
