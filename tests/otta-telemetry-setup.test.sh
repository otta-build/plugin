#!/usr/bin/env bash
# otta-telemetry-setup.test.sh — regression tests for scripts/otta-telemetry-setup.sh (#22).
# The writer merges an OTEL `env` block into .claude/settings.local.json (gitignored,
# token-bearing) so /otta:setup can turn on Claude Code telemetry → Pulse.
#
# Covers AC1–AC7:
#   logs-only by default; --traces adds the 4 beta/traces vars; OTTA_PULSE_URL
#   override (else hosted default); MERGE preserves pre-existing env + top-level
#   keys; token lands ONLY in settings.local.json (never settings.json) and the
#   file is gitignored; idempotent re-run (valid JSON, no dupes).
# Run: bash tests/otta-telemetry-setup.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-telemetry-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

REPO_SLUG="acme/widget"
TOKEN="pulse_tok_SECRET123"
SETTINGS=".claude/settings.local.json"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

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
# 1. AC1/AC2 — logs-only by default: 6 logs vars set, NO traces/beta vars
# ---------------------------------------------------------------------------
R="$(newrepo logs)"; cd "$R"
unset OTTA_PULSE_URL
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "logs-only run exited non-zero"
[ -f "$SETTINGS" ] || fail "settings.local.json not created"
valid_json "$SETTINGS" || fail "settings.local.json is not valid JSON"
[ "$(getenv "$SETTINGS" CLAUDE_CODE_ENABLE_TELEMETRY)" = "1" ] || fail "CLAUDE_CODE_ENABLE_TELEMETRY != 1"
[ "$(getenv "$SETTINGS" OTEL_LOGS_EXPORTER)" = "otlp" ] || fail "OTEL_LOGS_EXPORTER != otlp"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_PROTOCOL)" = "http/json" ] || fail "logs protocol wrong"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT)" = "https://pulse.otta.build/v1/logs" ] || \
  fail "logs endpoint wrong: $(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT)"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_HEADERS)" = "x-pulse-token=$TOKEN" ] || fail "headers token wrong"
[ "$(getenv "$SETTINGS" OTEL_RESOURCE_ATTRIBUTES)" = "repo=$REPO_SLUG" ] || fail "resource attrs wrong"
# NO traces/beta vars
for k in CLAUDE_CODE_ENHANCED_TELEMETRY_BETA OTEL_TRACES_EXPORTER OTEL_EXPORTER_OTLP_TRACES_PROTOCOL OTEL_EXPORTER_OTLP_TRACES_ENDPOINT; do
  [ -z "$(getenv "$SETTINGS" "$k")" ] || fail "traces var $k present without --traces"
done
pass "AC1/AC2: logs-only default (6 logs vars, no traces vars)"

# ---------------------------------------------------------------------------
# 2. AC3 — --traces adds the 4 traces vars incl. beta flag (logs still present)
# ---------------------------------------------------------------------------
R="$(newrepo traces)"; cd "$R"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" --traces || fail "--traces run exited non-zero"
[ "$(getenv "$SETTINGS" CLAUDE_CODE_ENHANCED_TELEMETRY_BETA)" = "1" ] || fail "beta flag not set with --traces"
[ "$(getenv "$SETTINGS" OTEL_TRACES_EXPORTER)" = "otlp" ] || fail "OTEL_TRACES_EXPORTER != otlp"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_TRACES_PROTOCOL)" = "http/json" ] || fail "traces protocol wrong"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)" = "https://pulse.otta.build/v1/traces" ] || \
  fail "traces endpoint wrong: $(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)"
# logs still there
[ "$(getenv "$SETTINGS" CLAUDE_CODE_ENABLE_TELEMETRY)" = "1" ] || fail "logs vars dropped under --traces"
pass "AC3: --traces adds 4 traces vars incl. beta flag"

# ---------------------------------------------------------------------------
# 3. AC2 — OTTA_PULSE_URL override respected (self-host), no trailing-slash dup
# ---------------------------------------------------------------------------
R="$(newrepo selfhost)"; cd "$R"
OTTA_PULSE_URL="https://pulse.acme.example/" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" --traces || fail "self-host run failed"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT)" = "https://pulse.acme.example/v1/logs" ] || \
  fail "self-host logs endpoint wrong: $(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_LOGS_ENDPOINT)"
[ "$(getenv "$SETTINGS" OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)" = "https://pulse.acme.example/v1/traces" ] || \
  fail "self-host traces endpoint wrong"
pass "AC2: OTTA_PULSE_URL override respected (trailing slash normalized)"

# ---------------------------------------------------------------------------
# 4. AC1/AC7 — MERGE: pre-existing env key + other top-level keys preserved
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
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "merge run exited non-zero"
valid_json "$SETTINGS" || fail "merge produced invalid JSON"
[ "$(getenv "$SETTINGS" MY_EXISTING_VAR)" = "keep-me" ] || fail "pre-existing env var clobbered"
[ "$(getenv "$SETTINGS" CLAUDE_CODE_ENABLE_TELEMETRY)" = "1" ] || fail "telemetry not merged into existing env"
[ "$(top "$SETTINGS" model)" = "claude-sonnet" ] || fail "top-level 'model' key lost"
# permissions (a dict) survives
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('permissions',{}).get('allow')==['Bash'] else 1)" "$SETTINGS" \
  || fail "top-level 'permissions' key lost"
pass "AC1/AC7: merge preserves pre-existing env var + other top-level keys"

# ---------------------------------------------------------------------------
# 5. AC4 — token ONLY in settings.local.json; committed settings.json NOT
#          written with token; .gitignore covers settings.local.json
# ---------------------------------------------------------------------------
R="$(newrepo gitignore)"; cd "$R"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" --traces || fail "gitignore run failed"
grep -q "$TOKEN" "$SETTINGS" || fail "token not found in settings.local.json"
# committed settings.json must NOT exist / must not carry the token
if [ -f .claude/settings.json ]; then
  grep -q "$TOKEN" .claude/settings.json && fail "token leaked into committed settings.json"
fi
# .gitignore behaviorally covers the file (check-ignore, not just grep)
git check-ignore "$SETTINGS" >/dev/null 2>&1 || fail ".gitignore does not actually ignore $SETTINGS"
# and the token-bearing file is therefore not staged by `git add -A`
git add -A
git status --porcelain | grep -q "settings.local.json" && fail "settings.local.json got staged despite gitignore"
git status --porcelain | while read -r line; do
  f="${line:3}"
  if grep -q "$TOKEN" "$f" 2>/dev/null; then echo "STAGED_TOKEN:$f"; fi
done | grep -q STAGED_TOKEN && fail "a staged file contains the token"
pass "AC4: token only in gitignored settings.local.json; never staged/committed"

# ---------------------------------------------------------------------------
# 6. AC1/AC7 — idempotent re-run: valid JSON, no duplicate keys, same values
# ---------------------------------------------------------------------------
R="$(newrepo idempotent)"; cd "$R"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" --traces || fail "idempotent run 1 failed"
FIRST="$(cat "$SETTINGS")"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" --traces || fail "idempotent run 2 failed"
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
# 7. usage guard — missing args exit non-zero (interface contract)
# ---------------------------------------------------------------------------
R="$(newrepo usage)"; cd "$R"
if bash "$SCRIPT" >/dev/null 2>&1; then fail "missing args should exit non-zero"; fi
if bash "$SCRIPT" "$REPO_SLUG" >/dev/null 2>&1; then fail "missing token should exit non-zero"; fi
pass "usage guard: missing repo/token rejected"

echo "All otta-telemetry-setup tests passed."
