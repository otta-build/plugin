#!/usr/bin/env bash
# otta-telemetry-setup.test.sh — regression tests for scripts/otta-telemetry-setup.sh.
# The writer derives a per-repo token via Pulse /token, then merges an OTEL `env`
# block into .claude/settings.local.json (gitignored, token-bearing — NEVER the
# committed settings.json) so /otta:setup can turn on Claude Code telemetry → Pulse.
#
# Covers AC1–AC7 (original), AC3 (plugin#32):
#   - /token endpoint called with webhook secret → derived token stored, secret never stored
#   - logs-only by default; --traces adds 4 beta/traces vars; OTTA_PULSE_URL override
#   - MERGE preserves pre-existing env + top-level keys
#   - token lands ONLY in settings.local.json (never settings.json) and the file is gitignored
#   - idempotent re-run (valid JSON, no dupes)
# Run: bash tests/otta-telemetry-setup.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-telemetry-setup.sh"
TMP="$(mktemp -d)"
STUB_PID=""
trap 'rm -rf "$TMP"; [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true' EXIT
fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

REPO_SLUG="acme/widget"
WEBHOOK_SECRET="webhook_sec_RAWSECRET999"
DERIVED_TOKEN="test-derived-token-abc123"
STUB_PORT=19876
SETTINGS=".claude/settings.local.json"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

# ---------------------------------------------------------------------------
# Start HTTP stub — responds to GET /token with {"token":"test-derived-token-abc123"}
# ---------------------------------------------------------------------------
python3 -c "
import http.server, json, threading
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'token':'test-derived-token-abc123'}).encode())
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', ${STUB_PORT}), H)
t = threading.Thread(target=s.serve_forever)
t.daemon = True
t.start()
import time; time.sleep(120)
" &
STUB_PID=$!

# Wait for stub to be ready (poll up to 3s)
for i in $(seq 1 30); do
  python3 -c "import socket; s=socket.socket(); s.settimeout(0.2); s.connect(('127.0.0.1',${STUB_PORT})); s.close()" 2>/dev/null && break
  sleep 0.1
done

STUB_URL="http://127.0.0.1:${STUB_PORT}"

# JSON value reader: prints env.<KEY> from settings.local.json, empty if absent.
getenv() { # <file> <key>
  python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print('__INVALID__'); sys.exit()
print(d.get('env',{}).get(sys.argv[2],''))
" "$1" "$2"
}
top() { # <file> <top-level-key>
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get(sys.argv[2],''))
" "$1" "$2"
}
valid_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2>/dev/null; }

newrepo() { # prints fresh git repo dir
  local d="$TMP/$1"
  git init -q -b main "$d"
  ( cd "$d" && git config user.email t@t.t && git config user.name t )
  echo "$d"
}

# ---------------------------------------------------------------------------
# 1. AC1 — /token called with webhook secret; derived token in headers; secret NOT stored
# ---------------------------------------------------------------------------
R="$(newrepo token-derive)"; cd "$R"
OTTA_PULSE_URL="$STUB_URL" bash "$SCRIPT" "$REPO_SLUG" "$WEBHOOK_SECRET" || fail "token-derive run exited non-zero"
[ -f "$SETTINGS" ] || fail "settings.local.json not created"
valid_json "$SETTINGS" || fail "settings.local.json is not valid JSON"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_HEADERS)" = "x-pulse-token=$DERIVED_TOKEN" ] || \
  fail "OTEL headers should contain derived token, got: $(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_HEADERS)"
grep -q "$WEBHOOK_SECRET" "$SETTINGS" && fail "webhook secret must NOT be written to settings.local.json"
pass "AC1 (plugin#32): derived token written, webhook secret not stored"

# ---------------------------------------------------------------------------
# 2. AC1/AC2 — logs-only by default: 6 logs vars set, NO traces/beta vars
# ---------------------------------------------------------------------------
R="$(newrepo logs)"; cd "$R"
OTTA_PULSE_URL="$STUB_URL" bash "$SCRIPT" "$REPO_SLUG" "$WEBHOOK_SECRET" || fail "logs-only run exited non-zero"
[ -f "$SETTINGS" ] || fail "settings.local.json not created"
valid_json "$SETTINGS" || fail "settings.local.json is not valid JSON"
[ "$(getenv "$SETTINGS" CLAUDE_CODE_ENABLE_TELEMETRY)" = "1" ] || fail "CLAUDE_CODE_ENABLE_TELEMETRY != 1"
[ "$(getenv "$SETTINGS" OTEL_LOGS_EXPORTER)" = "otlp" ] || fail "OTEL_LOGS_EXPORTER != otlp"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_PROTOCOL)" = "http/json" ] || fail "logs protocol wrong"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT)" = "${STUB_URL}/v1/logs" ] || \
  fail "logs endpoint wrong: $(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT)"
[ "$(getenv "$SETTINGS" OTEL_METRICS_EXPORTER)" = "otlp" ] || fail "OTEL_METRICS_EXPORTER != otlp"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_METRICS_PROTOCOL)" = "http/json" ] || fail "metrics protocol wrong"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_METRICS_ENDPOINT)" = "${STUB_URL}/v1/metrics" ] || \
  fail "metrics endpoint wrong: $(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_METRICS_ENDPOINT)"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_HEADERS)" = "x-pulse-token=$DERIVED_TOKEN" ] || fail "headers token wrong"
[ "$(getenv "$SETTINGS" OTEL_RESOURCE_ATTRIBUTES)" = "repo=$REPO_SLUG" ] || fail "resource attrs wrong"
# NO traces/beta vars
for k in CLAUDE_CODE_ENHANCED_TELEMETRY_BETA OTEL_TRACES_EXPORTER OTEL_EXPORTER_OTLP_TRACES_PROTOCOL OTEL_EXPORTER_OTLP_TRACES_ENDPOINT; do
  [ -z "$(getenv "$SETTINGS" "$k")" ] || fail "traces var $k present without --traces"
done
pass "AC1/AC2: logs-only default (6 logs vars, no traces vars)"

# ---------------------------------------------------------------------------
# 3. AC3 — --traces adds the 4 traces vars incl. beta flag (logs still present)
# ---------------------------------------------------------------------------
R="$(newrepo traces)"; cd "$R"
OTTA_PULSE_URL="$STUB_URL" bash "$SCRIPT" "$REPO_SLUG" "$WEBHOOK_SECRET" --traces || fail "--traces run exited non-zero"
[ "$(getenv "$SETTINGS" CLAUDE_CODE_ENHANCED_TELEMETRY_BETA)" = "1" ] || fail "beta flag not set with --traces"
[ "$(getenv "$SETTINGS" OTEL_TRACES_EXPORTER)" = "otlp" ] || fail "OTEL_TRACES_EXPORTER != otlp"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_TRACES_PROTOCOL)" = "http/json" ] || fail "traces protocol wrong"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)" = "${STUB_URL}/v1/traces" ] || \
  fail "traces endpoint wrong: $(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)"
# logs still there
[ "$(getenv "$SETTINGS" CLAUDE_CODE_ENABLE_TELEMETRY)" = "1" ] || fail "logs vars dropped under --traces"
pass "AC3: --traces adds 4 traces vars incl. beta flag"

# ---------------------------------------------------------------------------
# 4. AC2 — OTTA_PULSE_URL trailing-slash normalization (no doubled slash in endpoints)
# ---------------------------------------------------------------------------
R="$(newrepo selfhost)"; cd "$R"
OTTA_PULSE_URL="${STUB_URL}/" bash "$SCRIPT" "$REPO_SLUG" "$WEBHOOK_SECRET" --traces || fail "trailing-slash run failed"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT)" = "${STUB_URL}/v1/logs" ] || \
  fail "trailing-slash logs endpoint wrong: $(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT)"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)" = "${STUB_URL}/v1/traces" ] || \
  fail "trailing-slash traces endpoint wrong"
pass "AC2: OTTA_PULSE_URL override respected (trailing slash normalized)"

# ---------------------------------------------------------------------------
# 5. AC1/AC7 — MERGE: pre-existing env key + other top-level keys preserved
# ---------------------------------------------------------------------------
R="$(newrepo merge)"; cd "$R"
mkdir -p .claude
cat > "$SETTINGS" <<'EOF'
{
  "model": "claude-sonnet",
  "env": {
    "MY_EXISTING_VAR": "keep-me"
  },
  "permissions": { "allow": ["Bash"] }
}
EOF
OTTA_PULSE_URL="$STUB_URL" bash "$SCRIPT" "$REPO_SLUG" "$WEBHOOK_SECRET" || fail "merge run exited non-zero"
valid_json "$SETTINGS" || fail "merge produced invalid JSON"
[ "$(getenv "$SETTINGS" MY_EXISTING_VAR)" = "keep-me" ] || fail "pre-existing env var clobbered"
[ "$(getenv "$SETTINGS" CLAUDE_CODE_ENABLE_TELEMETRY)" = "1" ] || fail "telemetry not merged into existing env"
[ "$(top "$SETTINGS" model)" = "claude-sonnet" ] || fail "top-level 'model' key lost"
# permissions (a dict) survives
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('permissions',{}).get('allow')==['Bash'] else 1)" "$SETTINGS" \
  || fail "top-level 'permissions' key lost"
pass "AC1/AC7: merge preserves pre-existing env var + other top-level keys"

# ---------------------------------------------------------------------------
# 6. AC4 — derived token ONLY in settings.local.json; webhook secret never in any file;
#          committed settings.json NOT written; .gitignore covers settings.local.json
# ---------------------------------------------------------------------------
R="$(newrepo gitignore)"; cd "$R"
OTTA_PULSE_URL="$STUB_URL" bash "$SCRIPT" "$REPO_SLUG" "$WEBHOOK_SECRET" --traces || fail "gitignore run failed"
grep -q "$DERIVED_TOKEN" "$SETTINGS" || fail "derived token not found in settings.local.json"
grep -q "$WEBHOOK_SECRET" "$SETTINGS" && fail "webhook secret must NOT be in settings.local.json"
# committed settings.json must NOT exist / must not carry either secret
if [ -f .claude/settings.json ]; then
  grep -q "$DERIVED_TOKEN" .claude/settings.json && fail "derived token leaked into committed settings.json"
  grep -q "$WEBHOOK_SECRET" .claude/settings.json && fail "webhook secret leaked into committed settings.json"
fi
# .gitignore behaviorally covers the file (check-ignore, not just grep)
git check-ignore "$SETTINGS" >/dev/null 2>&1 || fail ".gitignore does not actually ignore $SETTINGS"
# and the token-bearing file is therefore not staged by `git add -A`
git add -A
git status --porcelain | grep -q "settings.local.json" && fail "settings.local.json got staged despite gitignore"
git status --porcelain | while read -r line; do
  f="${line:3}"
  if grep -q "$DERIVED_TOKEN" "$f" 2>/dev/null || grep -q "$WEBHOOK_SECRET" "$f" 2>/dev/null; then
    echo "STAGED_SECRET:$f"
  fi
done | grep -q STAGED_SECRET && fail "a staged file contains a secret or derived token"
pass "AC4 (plugin#32): derived token only in gitignored settings.local.json; webhook secret never stored or staged"

# ---------------------------------------------------------------------------
# 7. AC1/AC7 — idempotent re-run: valid JSON, no duplicate keys, same values
# ---------------------------------------------------------------------------
R="$(newrepo idempotent)"; cd "$R"
OTTA_PULSE_URL="$STUB_URL" bash "$SCRIPT" "$REPO_SLUG" "$WEBHOOK_SECRET" --traces || fail "idempotent run 1 failed"
FIRST="$(cat "$SETTINGS")"
OTTA_PULSE_URL="$STUB_URL" bash "$SCRIPT" "$REPO_SLUG" "$WEBHOOK_SECRET" --traces || fail "idempotent run 2 failed"
SECOND="$(cat "$SETTINGS")"
[ "$FIRST" = "$SECOND" ] || fail "re-run changed output (not idempotent)"
valid_json "$SETTINGS" || fail "idempotent re-run produced invalid JSON"
# no duplicate env keys (json.load would already collapse dupes; assert count via raw text count == 1 each)
for k in CLAUDE_CODE_ENABLE_TELEMETRY OTEL_LOGS_EXPORTER OTEL_TRACES_EXPORTER; do
  n="$(grep -c "\"$k\"" "$SETTINGS")"
  [ "$n" = "1" ] || fail "duplicate key $k appears $n times after re-run"
done
pass "AC1/AC7: idempotent re-run (stable, valid JSON, no dupes)"

# ---------------------------------------------------------------------------
# 8. usage guard — missing args exit non-zero (interface contract)
# ---------------------------------------------------------------------------
R="$(newrepo usage)"; cd "$R"
if bash "$SCRIPT" >/dev/null 2>&1; then fail "missing args should exit non-zero"; fi
if bash "$SCRIPT" "$REPO_SLUG" >/dev/null 2>&1; then fail "missing webhook-secret should exit non-zero"; fi
pass "usage guard: missing repo/webhook-secret rejected"

echo "All otta-telemetry-setup tests passed."
