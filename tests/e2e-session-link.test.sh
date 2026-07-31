#!/usr/bin/env bash
# e2e-session-link.test.sh — AC4 for plugin#61.
#
# End-to-end chain: otta-telemetry-setup.sh writes OTTA_PULSE_URL + OTTA_PULSE_TOKEN
# to .claude/settings.local.json → we read those values back from the file →
# _stamp_session_link (from otta-worktree.sh) POSTs /session-link using them.
#
# This test guards the actual bug: if the two lines are absent from telemetry-setup.sh,
# getenv returns empty → _stamp_session_link hits the "[ -z purl ] || [ -z ptok ]" guard
# → no POST → test 1 fails.
#
# The test extracts _stamp_session_link via awk so we call the real function.
# A Python stub handles both GET /token (for setup) and captures POST /session-link.
#
# Run: bash tests/e2e-session-link.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$HERE/../scripts/otta-telemetry-setup.sh"
WORKTREE_SCRIPT="$HERE/../scripts/otta-worktree.sh"
TMP="$(mktemp -d)"
STUB_PID=""
trap 'rm -rf "$TMP"; [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true' EXIT
fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

STUB_PORT=19877
CAPTURED="$TMP/captured.json"
DERIVED_TOKEN="test-derived-token-e2e"
SESSION_ID="test-session-abc999"
BRANCH="otta/61"
WEBHOOK_SECRET="raw-webhook-secret"
REPO_SLUG="acme/widget"

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

# JSON value reader: prints env.<KEY> from settings.local.json, empty if absent.
getenv() {
  python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print(''); sys.exit()
print(d.get('env',{}).get(sys.argv[2],''))
" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Start HTTP stub — serves GET /token + captures POST /session-link to $CAPTURED
# ---------------------------------------------------------------------------
python3 - "$STUB_PORT" "$CAPTURED" "$DERIVED_TOKEN" <<'PY' &
import http.server, json, sys, threading

port  = int(sys.argv[1])
out   = sys.argv[2]
token = sys.argv[3]

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'token': token}).encode())
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
for _ in $(seq 1 30); do
  python3 -c "import socket; s=socket.socket(); s.settimeout(0.2); s.connect(('127.0.0.1',$STUB_PORT)); s.close()" 2>/dev/null && break
  sleep 0.1
done

STUB_URL="http://127.0.0.1:${STUB_PORT}"
SETTINGS=".claude/settings.local.json"
WT_DIR="$TMP/worktree"
mkdir -p "$WT_DIR"

# ---------------------------------------------------------------------------
# 1. AC4 full chain: setup writes vars → read back → POST /session-link fires
#
#    Reverting the 2 lines in otta-telemetry-setup.sh causes:
#      getenv $SETTINGS OTTA_PULSE_URL → ""
#      _stamp_session_link hits "[ -z purl ] || [ -z ptok ] && return 0"
#      no POST → CAPTURED absent → this test fails.
# ---------------------------------------------------------------------------
rm -f "$CAPTURED"
REPO_DIR="$TMP/repo1"
git init -q -b main "$REPO_DIR"
( cd "$REPO_DIR" && git config user.email t@t.t && git config user.name t )
cd "$REPO_DIR"

OTTA_PULSE_URL="$STUB_URL" bash "$SETUP_SCRIPT" "$REPO_SLUG" "$WEBHOOK_SECRET" >/dev/null

WRITTEN_URL="$(getenv "$SETTINGS" OTTA_PULSE_URL)"
WRITTEN_TOKEN="$(getenv "$SETTINGS" OTTA_PULSE_TOKEN)"
[ -n "$WRITTEN_URL" ]   || fail "AC4 chain: OTTA_PULSE_URL not written by setup script (the 2-line fix is missing)"
[ -n "$WRITTEN_TOKEN" ] || fail "AC4 chain: OTTA_PULSE_TOKEN not written by setup script (the 2-line fix is missing)"

# Now call _stamp_session_link with values read from the file (not hardcoded)
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c "
$FUNC_CODE
OTTA_PULSE_URL='$WRITTEN_URL' OTTA_PULSE_TOKEN='$WRITTEN_TOKEN' CLAUDE_CODE_SESSION_ID='$SESSION_ID' \
  _stamp_session_link '$WT_DIR' '$BRANCH' '$REPO_SLUG'
"
sleep 0.2
[ -f "$CAPTURED" ] || fail "AC4 chain: /session-link POST not sent — check OTTA_PULSE_URL/TOKEN written correctly"
CAP_TOKEN="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['token'])" "$CAPTURED")"
CAP_BODY="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['body'])" "$CAPTURED")"
[ "$CAP_TOKEN" = "$DERIVED_TOKEN" ] || fail "AC4 chain: x-pulse-token wrong: got '$CAP_TOKEN', want '$DERIVED_TOKEN'"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get('session_id')=='$SESSION_ID' and d.get('branch')=='$BRANCH' else 1)" "$CAP_BODY" \
  || fail "AC4 chain: POST body wrong: $CAP_BODY"
pass "AC4 chain: setup writes vars → read from file → /session-link POST fires with correct token + body"

# ---------------------------------------------------------------------------
# 2. When OTTA_PULSE_TOKEN empty → NO POST (silent skip, guards worktree logic)
# ---------------------------------------------------------------------------
rm -f "$CAPTURED"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c "
$FUNC_CODE
OTTA_PULSE_URL='$STUB_URL' OTTA_PULSE_TOKEN='' CLAUDE_CODE_SESSION_ID='$SESSION_ID' \
  _stamp_session_link '$WT_DIR' '$BRANCH' '$REPO_SLUG' || true
"
sleep 0.2
[ ! -f "$CAPTURED" ] || fail "AC4: POST fired with empty OTTA_PULSE_TOKEN (should skip)"
pass "AC4: skips /session-link when OTTA_PULSE_TOKEN is empty"

# ---------------------------------------------------------------------------
# 3. When OTTA_PULSE_URL empty → NO POST (silent skip, guards worktree logic)
# ---------------------------------------------------------------------------
rm -f "$CAPTURED"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c "
$FUNC_CODE
OTTA_PULSE_URL='' OTTA_PULSE_TOKEN='$DERIVED_TOKEN' CLAUDE_CODE_SESSION_ID='$SESSION_ID' \
  _stamp_session_link '$WT_DIR' '$BRANCH' '$REPO_SLUG' || true
"
sleep 0.2
[ ! -f "$CAPTURED" ] || fail "AC4: POST fired with empty OTTA_PULSE_URL (should skip)"
pass "AC4: skips /session-link when OTTA_PULSE_URL is empty"

# ---------------------------------------------------------------------------
# 4. When CLAUDE_CODE_SESSION_ID unset → NO POST (use env -u to scrub CC env)
# ---------------------------------------------------------------------------
rm -f "$CAPTURED"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c "
$FUNC_CODE
OTTA_PULSE_URL='$STUB_URL' OTTA_PULSE_TOKEN='$DERIVED_TOKEN' \
  _stamp_session_link '$WT_DIR' '$BRANCH' '$REPO_SLUG' || true
"
sleep 0.2
[ ! -f "$CAPTURED" ] || fail "AC4: POST fired with no CLAUDE_CODE_SESSION_ID (should skip)"
pass "AC4: skips /session-link when CLAUDE_CODE_SESSION_ID is unset"

echo "All e2e-session-link tests passed."
