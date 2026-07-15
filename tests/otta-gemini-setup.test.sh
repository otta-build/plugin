#!/usr/bin/env bash
# otta-gemini-setup.test.sh — regression tests for scripts/otta-gemini-setup.sh (issue #51).
# Writes .gemini/settings.json (telemetry.target=local + otlpEndpoint/otlpProtocol,
# direct OTLP/HTTP export) and .otta/gemini.env (OTEL_EXPORTER_OTLP_HEADERS auth).
# No collector sidecar — see script header for the source-verified rationale.
# Run: bash tests/otta-gemini-setup.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-gemini-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

REPO_SLUG="acme/widget"
TOKEN="pulse_tok_SECRET123"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

# JSON value reader: prints nested key from settings.json, empty if absent.
getjson() { # <file> <dotted-key>
  python3 -c "
import json, sys
path = sys.argv[1]
keys = sys.argv[2].split('.')
try:
    d = json.load(open(path))
    for k in keys:
        d = d[k]
    print(d)
except Exception:
    print('')
" "$1" "$2"
}

valid_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. Basic write: .gemini/settings.json + .otta/gemini.env created, no collector yaml
# ---------------------------------------------------------------------------
RDIR="$TMP/repo1"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "basic run exited non-zero"
[ -f ".gemini/settings.json" ] || fail ".gemini/settings.json not created"
[ -f ".otta/gemini.env" ] || fail ".otta/gemini.env not created"
[ -f "otel-collector-config.yaml" ] && fail "otel-collector-config.yaml should NOT be created (direct export, no collector)"
valid_json ".gemini/settings.json" || fail ".gemini/settings.json is not valid JSON"
pass "AC3: settings.json + gemini.env created, no collector yaml"

# ---------------------------------------------------------------------------
# 2. settings.json: telemetry.enabled=true, target=local, otlpEndpoint (base
#    URL, no /v1 — Gemini's exporter joins v1/logs etc itself), otlpProtocol=http
# ---------------------------------------------------------------------------
RDIR="$TMP/repo2"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "settings run exited non-zero"
ENABLED="$(getjson ".gemini/settings.json" "telemetry.enabled")"
[ "$ENABLED" = "True" ] || \
  fail "telemetry.enabled wrong (must be true): $ENABLED"
TARGET="$(getjson ".gemini/settings.json" "telemetry.target")"
[ "$TARGET" = "local" ] || \
  fail "telemetry.target wrong (must be local — gcp only applies to Vertex/GCP export): $TARGET"
OTLP_ENDPOINT="$(getjson ".gemini/settings.json" "telemetry.otlpEndpoint")"
[ "$OTLP_ENDPOINT" = "https://pulse.otta.build" ] || \
  fail "telemetry.otlpEndpoint wrong: $OTLP_ENDPOINT"
PROTOCOL="$(getjson ".gemini/settings.json" "telemetry.otlpProtocol")"
[ "$PROTOCOL" = "http" ] || \
  fail "telemetry.otlpProtocol wrong: $PROTOCOL"
pass "AC3: telemetry.enabled=true, target=local, otlpEndpoint=pulse base URL, otlpProtocol=http"

# ---------------------------------------------------------------------------
# 3. .otta/gemini.env: OTEL_EXPORTER_OTLP_HEADERS carries x-pulse-token=<token>
#    (the standard OTel JS SDK header env var Gemini's exporters fall back to
#    when no explicit `headers` option is passed — verified in gemini-cli
#    source, sdk.ts constructs OTLPTraceExporterHttp/etc with only `url`.)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo3"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "headers run exited non-zero"
[ "$(bash -c 'source "$1"; printf "%s" "$OTEL_EXPORTER_OTLP_HEADERS"' _ .otta/gemini.env)" = "x-pulse-token=$TOKEN" ] || \
  fail "OTEL_EXPORTER_OTLP_HEADERS does not round-trip with x-pulse-token=<token>"
pass "AC3: OTEL_EXPORTER_OTLP_HEADERS=x-pulse-token=<token> present in gemini.env"

# ---------------------------------------------------------------------------
# 4. .otta/gemini.env: OTEL_RESOURCE_ATTRIBUTES contains repo slug and harness=gemini
# ---------------------------------------------------------------------------
RDIR="$TMP/repo4"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "resource attrs run exited non-zero"
[ "$(bash -c 'source "$1"; printf "%s" "$OTEL_RESOURCE_ATTRIBUTES"' _ .otta/gemini.env)" = "repo=$REPO_SLUG,harness=gemini" ] || \
  fail "OTEL_RESOURCE_ATTRIBUTES does not round-trip with repo+harness=gemini"
pass "AC3: OTEL_RESOURCE_ATTRIBUTES=repo=...,harness=gemini present"

# ---------------------------------------------------------------------------
# 4b. .otta/gemini.env: GEMINI_CLI_TRUST_WORKSPACE=true — required or Gemini's
#     folder-trust feature silently drops workspace .gemini/settings.json
#     (confirmed in gemini-cli's settings.ts mergeSettings: untrusted
#     workspace settings are replaced with {} before merge).
# ---------------------------------------------------------------------------
RDIR="$TMP/repo4b"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "trust-workspace run exited non-zero"
[ "$(bash -c 'source "$1"; printf "%s" "$GEMINI_CLI_TRUST_WORKSPACE"' _ .otta/gemini.env)" = "true" ] || \
  fail "GEMINI_CLI_TRUST_WORKSPACE=true not set — workspace settings.json would be silently ignored"
pass "AC3: GEMINI_CLI_TRUST_WORKSPACE=true present (workspace settings.json would else be dropped)"

# ---------------------------------------------------------------------------
# 5. pulse URL base-only (no /v1 suffix) — default + OTTA_PULSE_URL override,
#    trailing slash normalized
# ---------------------------------------------------------------------------
RDIR="$TMP/repo5"
mkdir -p "$RDIR"
cd "$RDIR"
OTTA_PULSE_URL="https://pulse.acme.example/" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || \
  fail "override pulse URL run failed"
[ "$(getjson ".gemini/settings.json" "telemetry.otlpEndpoint")" = "https://pulse.acme.example" ] || \
  fail "override pulse URL endpoint wrong: $(getjson ".gemini/settings.json" "telemetry.otlpEndpoint")"
pass "AC3: OTTA_PULSE_URL override respected (trailing slash normalized, base URL only)"

# ---------------------------------------------------------------------------
# 6. Merge: pre-existing settings.json keys preserved (idempotent JSON merge)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo6"
mkdir -p "$RDIR/.gemini"
cd "$RDIR"
cat > ".gemini/settings.json" <<'JSON'
{
  "model": "gemini-2.0-flash",
  "theme": "dark"
}
JSON
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "merge run exited non-zero"
valid_json ".gemini/settings.json" || fail "merge produced invalid JSON"
[ "$(getjson ".gemini/settings.json" "model")" = "gemini-2.0-flash" ] || \
  fail "merge: pre-existing 'model' key clobbered"
[ "$(getjson ".gemini/settings.json" "theme")" = "dark" ] || \
  fail "merge: pre-existing 'theme' key clobbered"
[ "$(getjson ".gemini/settings.json" "telemetry.otlpEndpoint")" = "https://pulse.otta.build" ] || \
  fail "merge: telemetry.otlpEndpoint not merged"
pass "AC3: merge preserves pre-existing settings.json keys"

# ---------------------------------------------------------------------------
# 6b. Malformed settings.json (non-empty, invalid JSON): must exit non-zero
#     and NOT overwrite the file or write .otta/gemini.env — a silent
#     data-loss hazard if the script blindly treated a parse failure as
#     "start empty" and clobbered the user's existing (broken but theirs)
#     config. Empty/absent files still fall back to {} per existing behavior.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo6b"
mkdir -p "$RDIR/.gemini"
cd "$RDIR"
MALFORMED='{ "model": "gemini-2.0-flash", invalid json here'
printf '%s' "$MALFORMED" > ".gemini/settings.json"
if OUT="$(bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" 2>&1)"; then
  fail "malformed settings.json: script must exit non-zero, not proceed"
fi
echo "$OUT" | grep -qF '.gemini/settings.json' || \
  fail "error must name the offending file (.gemini/settings.json): got: $OUT"
AFTER="$(cat ".gemini/settings.json")"
[ "$AFTER" = "$MALFORMED" ] || \
  fail "malformed settings.json was overwritten (data loss): got: $AFTER"
[ ! -f ".otta/gemini.env" ] || fail "malformed settings.json: .otta/gemini.env should not have been written"
pass "AC3: malformed non-empty settings.json exits non-zero, no partial writes"

# ---------------------------------------------------------------------------
# 6c. Valid JSON but non-object settings.json (array/string/number): same
#     data-loss shape as 6b — must fail loud (exit non-zero, error naming the
#     file, no writes) instead of silently resetting to {} and clobbering.
# ---------------------------------------------------------------------------
for NONOBJ in '[1,2,3]' '"just a string"' '42'; do
  RDIR="$TMP/repo6c-$(echo "$NONOBJ" | tr -dc 'a-zA-Z0-9')"
  mkdir -p "$RDIR/.gemini"
  cd "$RDIR"
  printf '%s' "$NONOBJ" > ".gemini/settings.json"
  if OUT="$(bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" 2>&1)"; then
    fail "non-object settings.json ($NONOBJ): script must exit non-zero, not proceed"
  fi
  echo "$OUT" | grep -qF '.gemini/settings.json' || \
    fail "non-object settings.json ($NONOBJ): error must name the offending file: got: $OUT"
  AFTER="$(cat ".gemini/settings.json")"
  [ "$AFTER" = "$NONOBJ" ] || \
    fail "non-object settings.json ($NONOBJ) was overwritten (data loss): got: $AFTER"
  [ ! -f ".otta/gemini.env" ] || fail "non-object settings.json ($NONOBJ): .otta/gemini.env should not have been written"
done
pass "AC3: valid-but-non-object settings.json exits non-zero, no partial writes"

# ---------------------------------------------------------------------------
# 7. Idempotent: re-run produces byte-identical output for both files
# ---------------------------------------------------------------------------
RDIR="$TMP/repo7"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent run 1 failed"
FIRST_SETTINGS="$(cat .gemini/settings.json)"
FIRST_ENV="$(cat .otta/gemini.env)"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent run 2 failed"
SECOND_SETTINGS="$(cat .gemini/settings.json)"
SECOND_ENV="$(cat .otta/gemini.env)"
[ "$FIRST_SETTINGS" = "$SECOND_SETTINGS" ] || fail "settings.json not idempotent on re-run"
[ "$FIRST_ENV" = "$SECOND_ENV" ] || fail ".otta/gemini.env not idempotent on re-run"
pass "AC3: idempotent re-run (stable output for both files)"

# ---------------------------------------------------------------------------
# 8. Gitignore: .gemini/settings.json and .otta/gemini.env both added (idempotent)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo8"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "gitignore run failed"
grep -qF '.gemini/settings.json' ".gitignore" || fail ".gitignore: .gemini/settings.json not added"
grep -qF '.otta/gemini.env' ".gitignore" || fail ".gitignore: .otta/gemini.env not added"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "gitignore idempotent run failed"
N1="$(grep -c '\.gemini/settings\.json' ".gitignore")"
N2="$(grep -c '\.otta/gemini\.env' ".gitignore")"
[ "$N1" = "1" ] || fail ".gitignore: settings.json pattern duplicated after re-run (count=$N1)"
[ "$N2" = "1" ] || fail ".gitignore: gemini.env pattern duplicated after re-run (count=$N2)"
pass "AC3: .gitignore updated with both files (idempotent)"

# ---------------------------------------------------------------------------
# 9. Token not staged: literal token not in any git-staged file
# ---------------------------------------------------------------------------
RDIR="$TMP/repo9"
mkdir -p "$RDIR"
cd "$RDIR"
git init -q -b main
git config user.email t@t.t
git config user.name t
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "token-staged run failed"
git add -A
STAGED_WITH_TOKEN="$(git diff --cached --name-only | while read -r f; do
  grep -q "$TOKEN" "$f" 2>/dev/null && echo "$f" || true
done)"
[ -z "$STAGED_WITH_TOKEN" ] || fail "literal token found in staged file(s): $STAGED_WITH_TOKEN"
pass "AC3: literal token not in any staged file"

# ---------------------------------------------------------------------------
# 10. Output: consent disclosure + direct-export framing (no docker/collector
#     instructions — this is the corrected mechanism from issue #51)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo10"
mkdir -p "$RDIR"
cd "$RDIR"
OUT="$(bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" 2>&1)"
echo "$OUT" | grep -q 'pulse.otta.build' || fail "AC1: consent disclosure missing pulse.otta.build"
echo "$OUT" | grep -qi 'docker' && fail "AC1: output should not mention docker — direct export needs no collector"
echo "$OUT" | grep -qi 'gemini.env' || fail "AC1: output missing instructions to source gemini.env"
echo "$OUT" | grep -qi 'TRUST_WORKSPACE\|folder-trust' || fail "AC1: output missing folder-trust caveat"
pass "AC1: consent disclosure printed; no docker/collector instructions; folder-trust caveat present"

# ---------------------------------------------------------------------------
# 11. Usage guard: missing args exit non-zero
# ---------------------------------------------------------------------------
RDIR="$TMP/repo11"
mkdir -p "$RDIR"
cd "$RDIR"
if OTTA_PULSE_TOKEN= bash "$SCRIPT" >/dev/null 2>&1; then fail "missing args should exit non-zero"; fi
if OTTA_PULSE_TOKEN= bash "$SCRIPT" "$REPO_SLUG" >/dev/null 2>&1; then fail "missing token should exit non-zero"; fi
pass "usage guard: missing repo/token rejected"

# ---------------------------------------------------------------------------
# 12. AC5: --derive hosted mode reuses .otta/pulse.env and never calls /token.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo12"
mkdir -p "$RDIR/.otta"
cd "$RDIR"
printf 'OTTA_PULSE_URL=https://pulse.otta.build\nOTTA_PULSE_TOKEN=hosted-derived-fixture\n' > .otta/pulse.env
mkdir -p "$TMP/gemini-derive-bin"
cat > "$TMP/gemini-derive-bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
echo "$@" >> "${CURL_ARGS_FILE:-/dev/null}"
exit 1
CURL_STUB
chmod +x "$TMP/gemini-derive-bin/curl"
OUT="$(CURL_ARGS_FILE="$TMP/gemini12-curl.txt" PATH="$TMP/gemini-derive-bin:$PATH" bash "$SCRIPT" --derive "$REPO_SLUG" 2>&1)" || \
  fail "AC5: hosted --derive run exited non-zero"
[ ! -s "$TMP/gemini12-curl.txt" ] || fail "AC5: hosted --derive called curl/self-hosted /token path"
[ "$(bash -c 'source "$1"; printf "%s" "$OTEL_EXPORTER_OTLP_HEADERS"' _ .otta/gemini.env)" = "x-pulse-token=hosted-derived-fixture" ] || \
  fail "AC5: hosted --derive did not write derived token into gemini.env"
! printf '%s' "$OUT" | grep -q 'hosted-derived-fixture' || fail "AC5: derived token leaked into stdout/stderr"
pass "AC5: hosted --derive reuses pulse.env and keeps the repo token private"

# ---------------------------------------------------------------------------
# 13. AC5: --derive self-hosted mode requires and sends the webhook secret,
#     but stores only the derived token.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo13"
mkdir -p "$RDIR"
cd "$RDIR"
SELFHOST_SECRET="webhook-secret-xyz"
cat > "$TMP/gemini-derive-bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
echo "$@" >> "${CURL_ARGS_FILE:-/dev/null}"
printf '{"token":"hosted-derived-fixture"}'
exit 0
CURL_STUB
chmod +x "$TMP/gemini-derive-bin/curl"
OUT="$(CURL_ARGS_FILE="$TMP/gemini13-curl.txt" PATH="$TMP/gemini-derive-bin:$PATH" \
  OTTA_PULSE_URL="https://pulse.example.test" \
  bash "$SCRIPT" --derive "$REPO_SLUG" "$SELFHOST_SECRET" 2>&1)" || \
  fail "AC5: self-hosted --derive run exited non-zero"
grep -q 'https://pulse.example.test/token?repo=acme/widget' "$TMP/gemini13-curl.txt" || \
  fail "AC5: self-hosted --derive did not call /token with repo query param"
grep -q "x-pulse-token: $SELFHOST_SECRET" "$TMP/gemini13-curl.txt" || \
  fail "AC5: self-hosted --derive did not send webhook secret as x-pulse-token"
[ "$(bash -c 'source "$1"; printf "%s" "$OTEL_EXPORTER_OTLP_HEADERS"' _ .otta/gemini.env)" = "x-pulse-token=hosted-derived-fixture" ] || \
  fail "AC5: self-hosted --derive did not write derived token into gemini.env"
! printf '%s' "$OUT" | grep -q "$SELFHOST_SECRET\|hosted-derived-fixture" || \
  fail "AC5: webhook secret or derived token leaked into stdout/stderr"
pass "AC5: self-hosted --derive uses the webhook secret only for derivation"

# ---------------------------------------------------------------------------
# 14. AC5: --derive usage guards.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo14"
mkdir -p "$RDIR"
cd "$RDIR"
if PATH="$TMP/gemini-derive-bin:$PATH" bash "$SCRIPT" --derive >/dev/null 2>&1; then
  fail "--derive with no repo should exit non-zero"
fi
if OTTA_PULSE_URL="https://pulse.example.test" PATH="$TMP/gemini-derive-bin:$PATH" \
    bash "$SCRIPT" --derive "$REPO_SLUG" >/dev/null 2>&1; then
  fail "--derive self-hosted with no webhook secret should exit non-zero"
fi
pass "AC5: --derive usage guards (missing repo / missing self-hosted secret)"

echo "All otta-gemini-setup tests passed."
