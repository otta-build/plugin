#!/usr/bin/env bash
# e2e-session-link.test.sh — AC4 for plugin#61.
#
# Verifies that when OTTA_PULSE_URL and OTTA_PULSE_TOKEN are present (written by
# otta-telemetry-setup.sh after the fix), _stamp_session_link in otta-worktree.sh
# POSTs to /session-link with the correct body and token header.
#
# The test extracts _stamp_session_link from otta-worktree.sh using awk (so we
# call the real function, not a reimplementation), then drives it against an
# in-process Python HTTP stub that captures the POST to a temp file.
#
# Run: bash tests/e2e-session-link.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="$HERE/../scripts/otta-worktree.sh"
TMP="$(mktemp -d)"
STUB_PID=""
trap 'rm -rf "$TMP"; [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true' EXIT
fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

STUB_PORT=19877
CAPTURED="$TMP/captured.json"
SESSION_ID="test-session-abc999"
BRANCH="otta/61"
REPO_FULL="acme/widget"
TOKEN="test-token-xyz"

# ---------------------------------------------------------------------------
# Extract _stamp_session_link from otta-worktree.sh (awk: function body only)
# ---------------------------------------------------------------------------
FUNC_CODE="$(awk '
  /^_stamp_session_link\(\)/{found=1; depth=0}
  found {
    for(i=1;i<=length($0);i++){
      c=substr($0,i,1)
      if(c=="{") depth++
      if(c=="}") depth--
    }
    print
    if(found && depth==0){ exit }
  }
' "$WORKTREE_SCRIPT")"
[ -n "$FUNC_CODE" ] || fail "could not extract _stamp_session_link from $WORKTREE_SCRIPT"

# ---------------------------------------------------------------------------
# Start HTTP stub — captures POST /session-link body to $CAPTURED
# ---------------------------------------------------------------------------
python3 - "$STUB_PORT" "$CAPTURED" <<'PY' &
import http.server, json, sys, threading, io

port = int(sys.argv[1])
out  = sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'token':'ignored'}).encode())
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body   = self.rfile.read(length).decode()
        captured = {
            'path':   self.path,
            'token':  self.headers.get('x-pulse-token',''),
            'body':   body,
        }
        with open(out, 'w') as f:
            json.dump(captured, f)
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass

s = http.server.HTTPServer(('127.0.0.1', port), H)
t = threading.Thread(target=s.serve_forever)
t.daemon = True
t.start()
import time; time.sleep(120)
PY
STUB_PID=$!

# Wait for stub to be ready (poll up to 3s)
for i in $(seq 1 30); do
  python3 -c "import socket; s=socket.socket(); s.settimeout(0.2); s.connect(('127.0.0.1',$STUB_PORT)); s.close()" 2>/dev/null && break
  sleep 0.1
done

STUB_URL="http://127.0.0.1:${STUB_PORT}"
WT_DIR="$TMP/worktree"
mkdir -p "$WT_DIR"

# ---------------------------------------------------------------------------
# 1. When session ID + both Pulse vars set → POST /session-link received
# (explicitly set SESSION_ID so test is independent of real CC session env)
# ---------------------------------------------------------------------------
rm -f "$CAPTURED"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c "
$FUNC_CODE
OTTA_PULSE_URL='$STUB_URL' OTTA_PULSE_TOKEN='$TOKEN' CLAUDE_CODE_SESSION_ID='$SESSION_ID' \
  _stamp_session_link '$WT_DIR' '$BRANCH' '$REPO_FULL'
"
sleep 0.2   # brief wait for stub to write file
[ -f "$CAPTURED" ] || fail "AC4: stub received no POST (CAPTURED file absent) — /session-link was not called"
CAP_PATH="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['path'])" "$CAPTURED")"
CAP_TOKEN="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['token'])" "$CAPTURED")"
CAP_BODY="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['body'])" "$CAPTURED")"
[[ "$CAP_PATH" == *"/session-link"* ]] || fail "AC4: POST path wrong: $CAP_PATH"
[ "$CAP_TOKEN" = "$TOKEN" ] || fail "AC4: x-pulse-token header wrong: $CAP_TOKEN"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('session_id')=='$SESSION_ID' and d.get('branch')=='$BRANCH' else 1)" "$CAP_BODY" \
  || fail "AC4: POST body wrong: $CAP_BODY"
pass "AC4: /session-link POST received with correct path, token header, and body"

# ---------------------------------------------------------------------------
# 2. When OTTA_PULSE_TOKEN empty → NO POST (silent skip)
# ---------------------------------------------------------------------------
rm -f "$CAPTURED"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c "
$FUNC_CODE
OTTA_PULSE_URL='$STUB_URL' OTTA_PULSE_TOKEN='' CLAUDE_CODE_SESSION_ID='$SESSION_ID' \
  _stamp_session_link '$WT_DIR' '$BRANCH' '$REPO_FULL' || true
"
sleep 0.2
[ ! -f "$CAPTURED" ] || fail "AC4: POST fired with empty OTTA_PULSE_TOKEN (should skip)"
pass "AC4: skips /session-link when OTTA_PULSE_TOKEN is empty"

# ---------------------------------------------------------------------------
# 3. When OTTA_PULSE_URL empty → NO POST (silent skip)
# ---------------------------------------------------------------------------
rm -f "$CAPTURED"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c "
$FUNC_CODE
OTTA_PULSE_URL='' OTTA_PULSE_TOKEN='$TOKEN' CLAUDE_CODE_SESSION_ID='$SESSION_ID' \
  _stamp_session_link '$WT_DIR' '$BRANCH' '$REPO_FULL' || true
"
sleep 0.2
[ ! -f "$CAPTURED" ] || fail "AC4: POST fired with empty OTTA_PULSE_URL (should skip)"
pass "AC4: skips /session-link when OTTA_PULSE_URL is empty"

# ---------------------------------------------------------------------------
# 4. When CLAUDE_CODE_SESSION_ID empty → NO POST (no session to link)
# (use env -u to scrub inherited Claude session vars from this CC process)
# ---------------------------------------------------------------------------
rm -f "$CAPTURED"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c "
$FUNC_CODE
OTTA_PULSE_URL='$STUB_URL' OTTA_PULSE_TOKEN='$TOKEN' \
  _stamp_session_link '$WT_DIR' '$BRANCH' '$REPO_FULL' || true
"
sleep 0.2
[ ! -f "$CAPTURED" ] || fail "AC4: POST fired with no CLAUDE_CODE_SESSION_ID (should skip)"
pass "AC4: skips /session-link when CLAUDE_CODE_SESSION_ID is unset"

echo "All e2e-session-link tests passed."
