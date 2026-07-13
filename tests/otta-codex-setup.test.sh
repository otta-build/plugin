#!/usr/bin/env bash
# otta-codex-setup.test.sh — regression tests for scripts/otta-codex-setup.sh (issue #50).
# Writes ~/.codex/config.toml [otel] block (primary); .otta/codex.env (legacy, backward compat).
# Run: bash tests/otta-codex-setup.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-codex-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

# Sandbox the Codex config dir for ALL tests so the suite never touches the
# developer's real ~/.codex/config.toml. Tests 13+ override CODEX_HOME locally
# for isolated assertions; this default catches tests 1-12 which predate the
# config.toml feature and don't set CODEX_HOME themselves.
export CODEX_HOME="$TMP/codex_home"
mkdir -p "$CODEX_HOME"

REPO_SLUG="acme/widget"
TOKEN="pulse_tok_SECRET123"

# ---------------------------------------------------------------------------
# 1. Basic write: .otta/codex.env created with required OTEL env vars
# ---------------------------------------------------------------------------
RDIR="$TMP/repo1"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "basic run exited non-zero"
ENV_FILE=".otta/codex.env"
[ -f "$ENV_FILE" ] || fail ".otta/codex.env not created"
grep -q 'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT' "$ENV_FILE" || \
  fail "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT not in $ENV_FILE"
grep -q 'https://pulse.otta.build/v1/logs' "$ENV_FILE" || \
  fail "endpoint value missing pulse.otta.build/v1/logs in $ENV_FILE"
pass "AC1: .otta/codex.env created with OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"

# ---------------------------------------------------------------------------
# 2. OTEL_RESOURCE_ATTRIBUTES contains repo slug and harness=codex
# ---------------------------------------------------------------------------
RDIR="$TMP/repo2"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "resource attrs run exited non-zero"
[ "$(bash -c 'source "$1"; printf "%s" "$OTEL_RESOURCE_ATTRIBUTES"' _ .otta/codex.env)" = "repo=$REPO_SLUG,harness=codex" ] || \
  fail "OTEL_RESOURCE_ATTRIBUTES does not round-trip with repo+harness=codex"
pass "AC1: OTEL_RESOURCE_ATTRIBUTES=repo=...,harness=codex present"

# ---------------------------------------------------------------------------
# 3. OTEL_EXPORTER_OTLP_LOGS_HEADERS contains x-pulse-token=<token>
# ---------------------------------------------------------------------------
RDIR="$TMP/repo3"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "headers run exited non-zero"
grep -q "OTEL_EXPORTER_OTLP_LOGS_HEADERS=x-pulse-token=$TOKEN" ".otta/codex.env" || \
  fail "OTEL_EXPORTER_OTLP_LOGS_HEADERS=x-pulse-token=<token> not found: $(cat .otta/codex.env)"
pass "AC1: OTEL_EXPORTER_OTLP_LOGS_HEADERS=x-pulse-token=<token> present"

# ---------------------------------------------------------------------------
# 4. OTTA_PULSE_URL override (self-host), trailing slash normalized
# ---------------------------------------------------------------------------
RDIR="$TMP/repo4"
mkdir -p "$RDIR"
cd "$RDIR"
OTTA_PULSE_URL="https://pulse.acme.example/" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || \
  fail "self-host run exited non-zero"
grep -q 'https://pulse.acme.example/v1/logs' ".otta/codex.env" || \
  fail "self-host endpoint wrong: $(grep OTLP_LOGS_ENDPOINT .otta/codex.env)"
pass "AC1: OTTA_PULSE_URL override respected (trailing slash normalized)"

# ---------------------------------------------------------------------------
# 5. Idempotent: re-run produces byte-identical output
# ---------------------------------------------------------------------------
RDIR="$TMP/repo5"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent run 1 failed"
FIRST="$(cat .otta/codex.env)"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent run 2 failed"
SECOND="$(cat .otta/codex.env)"
[ "$FIRST" = "$SECOND" ] || fail "re-run changed .otta/codex.env (not idempotent)"
pass "AC1: idempotent re-run (stable output)"

# ---------------------------------------------------------------------------
# 6. Gitignore: .otta/codex.env added to project .gitignore
# ---------------------------------------------------------------------------
RDIR="$TMP/repo6"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "gitignore run failed"
grep -qF '.otta/codex.env' ".gitignore" || fail ".gitignore: .otta/codex.env not added"
# Re-run does not duplicate the pattern
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "gitignore idempotent run failed"
N="$(grep -c '\.otta/codex\.env' ".gitignore")"
[ "$N" = "1" ] || fail ".gitignore: pattern duplicated after re-run (count=$N)"
pass "AC1: .otta/codex.env added to .gitignore (idempotent)"

# ---------------------------------------------------------------------------
# 7. AC3: consent disclosure mentions pulse.otta.build
# ---------------------------------------------------------------------------
RDIR="$TMP/repo7"
mkdir -p "$RDIR"
cd "$RDIR"
OUT="$(bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" 2>&1)"
echo "$OUT" | grep -q 'pulse.otta.build' || fail "AC3: consent disclosure missing pulse.otta.build"
pass "AC3: consent disclosure includes pulse.otta.build"

# ---------------------------------------------------------------------------
# 8. AC1: output mentions config.toml (not env-sourcing — Codex reads toml)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo8"
mkdir -p "$RDIR"
cd "$RDIR"
OUT="$(bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" 2>&1)"
echo "$OUT" | grep -q 'config.toml' || fail "AC1: output must mention config.toml (Codex reads toml, not env)"
pass "AC1: output mentions config.toml"

# ---------------------------------------------------------------------------
# 9. AC5: literal token NOT in any git-staged file
# ---------------------------------------------------------------------------
RDIR="$TMP/repo9"
mkdir -p "$RDIR"
cd "$RDIR"
git init -q -b main
git config user.email t@t.t
git config user.name t
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "token-staged run failed"
git add -A
# .otta/codex.env is gitignored so should not be staged
STAGED_WITH_TOKEN="$(git diff --cached --name-only | while read -r f; do
  grep -q "$TOKEN" "$f" 2>/dev/null && echo "$f" || true
done)"
[ -z "$STAGED_WITH_TOKEN" ] || fail "literal token found in staged file(s): $STAGED_WITH_TOKEN"
pass "AC5: literal token not in any staged file"

# ---------------------------------------------------------------------------
# 10. Usage guard: missing args exit non-zero
# ---------------------------------------------------------------------------
RDIR="$TMP/repo10"
mkdir -p "$RDIR"
cd "$RDIR"
if bash "$SCRIPT" >/dev/null 2>&1; then fail "missing args should exit non-zero"; fi
if OTTA_PULSE_TOKEN= bash "$SCRIPT" "$REPO_SLUG" >/dev/null 2>&1; then fail "missing token should exit non-zero"; fi
pass "usage guard: missing repo/token rejected"

# ---------------------------------------------------------------------------
# 11. AC1(#46): metrics exporter keys present in .otta/codex.env
# ---------------------------------------------------------------------------
RDIR="$TMP/repo11"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "metrics keys run exited non-zero"
ENV_FILE=".otta/codex.env"
grep -q 'OTEL_METRICS_EXPORTER=otlp' "$ENV_FILE" || \
  fail "OTEL_METRICS_EXPORTER=otlp not in $ENV_FILE"
grep -q 'https://pulse.otta.build/v1/metrics' "$ENV_FILE" || \
  fail "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT with /v1/metrics not in $ENV_FILE"
grep -q 'OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/json' "$ENV_FILE" || \
  fail "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/json not in $ENV_FILE"
grep -q "OTEL_EXPORTER_OTLP_METRICS_HEADERS=x-pulse-token=$TOKEN" "$ENV_FILE" || \
  fail "OTEL_EXPORTER_OTLP_METRICS_HEADERS=x-pulse-token=<token> not in $ENV_FILE"
pass "AC1(#46): metrics exporter keys present in .otta/codex.env"

# ---------------------------------------------------------------------------
# 12. AC1(#46): OTTA_PULSE_URL override applies to metrics endpoint too
# ---------------------------------------------------------------------------
RDIR="$TMP/repo12"
mkdir -p "$RDIR"
cd "$RDIR"
OTTA_PULSE_URL="https://pulse.acme.example/" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || \
  fail "metrics override run exited non-zero"
grep -q 'https://pulse.acme.example/v1/metrics' ".otta/codex.env" || \
  fail "OTTA_PULSE_URL override not reflected in OTLP_METRICS_ENDPOINT: $(grep METRICS_ENDPOINT .otta/codex.env || echo not-found)"
pass "AC1(#46): OTTA_PULSE_URL override reflected in metrics endpoint"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required for config.toml tests"; exit 0; }

# ---------------------------------------------------------------------------
# 13. AC1: config.toml created at $CODEX_HOME/config.toml
# ---------------------------------------------------------------------------
RDIR="$TMP/repo13"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex13"
mkdir -p "$CODEX_HOME"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "config.toml basic run exited non-zero"
[ -f "$CODEX_HOME/config.toml" ] || fail "config.toml not created at CODEX_HOME/config.toml"
pass "AC1: config.toml created at CODEX_HOME/config.toml"

# ---------------------------------------------------------------------------
# 14. AC1: config.toml has [otel] section with log_user_prompt and environment
# ---------------------------------------------------------------------------
RDIR="$TMP/repo14"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex14"
mkdir -p "$CODEX_HOME"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "otel section run exited non-zero"
grep -q '^\[otel\]' "$CODEX_HOME/config.toml" || \
  fail "config.toml missing [otel] section: $(cat "$CODEX_HOME/config.toml")"
grep -q 'log_user_prompt = false' "$CODEX_HOME/config.toml" || \
  fail "config.toml missing log_user_prompt = false"
grep -q 'environment = "production"' "$CODEX_HOME/config.toml" || \
  fail "config.toml missing environment = \"production\""
pass "AC1: config.toml [otel] section with log_user_prompt + environment"

# ---------------------------------------------------------------------------
# 15. AC1: config.toml has [otel.exporter.otlp-http] with endpoint + protocol
# ---------------------------------------------------------------------------
RDIR="$TMP/repo15"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex15"
mkdir -p "$CODEX_HOME"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "otlp-http run exited non-zero"
grep -q '^\[otel.exporter.otlp-http\]' "$CODEX_HOME/config.toml" || \
  fail "config.toml missing [otel.exporter.otlp-http]: $(cat "$CODEX_HOME/config.toml")"
grep -q 'endpoint = "https://pulse.otta.build/v1/logs"' "$CODEX_HOME/config.toml" || \
  fail "config.toml log endpoint wrong (must include /v1/logs): $(grep endpoint "$CODEX_HOME/config.toml" || echo not-found)"
grep -q 'protocol = "json"' "$CODEX_HOME/config.toml" || \
  fail "config.toml missing protocol = \"json\""
pass "AC1: config.toml [otel.exporter.otlp-http] with /v1/logs endpoint + protocol=json"

# Codex has no custom OTEL resource-attribute setting. Send the repo alongside
# the scoped token so Pulse can attribute and authenticate the stream.
grep -q "x-pulse-repo = \"$REPO_SLUG\"" "$CODEX_HOME/config.toml" || \
  fail "config.toml log/metrics headers must include x-pulse-repo"
[ "$(grep -c "x-pulse-repo = \"$REPO_SLUG\"" "$CODEX_HOME/config.toml")" = "2" ] || \
  fail "config.toml must write x-pulse-repo once for logs and once for metrics"
pass "AC1: config.toml attributes Codex logs and metrics with x-pulse-repo"

# ---------------------------------------------------------------------------
# 16. AC1: config.toml has [otel.exporter.otlp-http.headers] with x-pulse-token
# ---------------------------------------------------------------------------
RDIR="$TMP/repo16"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex16"
mkdir -p "$CODEX_HOME"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "headers run exited non-zero"
grep -q '^\[otel.exporter.otlp-http.headers\]' "$CODEX_HOME/config.toml" || \
  fail "config.toml missing [otel.exporter.otlp-http.headers]: $(cat "$CODEX_HOME/config.toml")"
grep -q "x-pulse-token = \"$TOKEN\"" "$CODEX_HOME/config.toml" || \
  fail "config.toml missing x-pulse-token = \"<token>\": $(cat "$CODEX_HOME/config.toml")"
pass "AC1: config.toml [otel.exporter.otlp-http.headers] with x-pulse-token"

# ---------------------------------------------------------------------------
# 17. AC1: OTTA_PULSE_URL override applies to config.toml endpoint
# ---------------------------------------------------------------------------
RDIR="$TMP/repo17"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex17"
mkdir -p "$CODEX_HOME"
OTTA_PULSE_URL="https://pulse.acme.example/" CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || \
  fail "OTTA_PULSE_URL override run exited non-zero"
grep -q 'endpoint = "https://pulse.acme.example/v1/logs"' "$CODEX_HOME/config.toml" || \
  fail "OTTA_PULSE_URL override not reflected in config.toml (must include /v1/logs): $(grep endpoint "$CODEX_HOME/config.toml" || echo not-found)"
pass "AC1: OTTA_PULSE_URL override (trailing slash normalized) in config.toml with /v1/logs"

# ---------------------------------------------------------------------------
# 18. AC1: config.toml merge preserves pre-existing non-otel content
# ---------------------------------------------------------------------------
RDIR="$TMP/repo18"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex18"
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<'TOML'
[model]
provider = "anthropic"
name = "claude-opus-4-5"

[history]
max_entries = 100
TOML
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "merge run exited non-zero"
grep -q '^\[model\]' "$CODEX_HOME/config.toml" || \
  fail "merge: [model] section clobbered: $(cat "$CODEX_HOME/config.toml")"
grep -q 'provider = "anthropic"' "$CODEX_HOME/config.toml" || \
  fail "merge: model.provider clobbered"
grep -q '^\[history\]' "$CODEX_HOME/config.toml" || \
  fail "merge: [history] section clobbered"
grep -q '^\[otel\]' "$CODEX_HOME/config.toml" || \
  fail "merge: [otel] section not written"
pass "AC1: config.toml merge preserves non-otel sections"

# ---------------------------------------------------------------------------
# 19. AC1: config.toml merge is idempotent (byte-stable, no duplicate otel)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo19"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex19"
mkdir -p "$CODEX_HOME"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent config.toml run 1 failed"
FIRST="$(cat "$CODEX_HOME/config.toml")"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent config.toml run 2 failed"
SECOND="$(cat "$CODEX_HOME/config.toml")"
[ "$FIRST" = "$SECOND" ] || fail "config.toml re-run is not idempotent (content changed)"
# No duplicate [otel] sections
N="$(grep -c '^\[otel\]' "$CODEX_HOME/config.toml")"
[ "$N" = "1" ] || fail "duplicate [otel] sections after re-run (count=$N)"
pass "AC1: config.toml idempotent re-run (byte-stable, no duplicate sections)"

# ---------------------------------------------------------------------------
# 20. AC1: legacy .otta/codex.env still written with "legacy" comment
# ---------------------------------------------------------------------------
RDIR="$TMP/repo20"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex20"
mkdir -p "$CODEX_HOME"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "legacy env run exited non-zero"
[ -f ".otta/codex.env" ] || fail "legacy .otta/codex.env not written"
grep -qi 'legacy\|does not read' ".otta/codex.env" || \
  fail "legacy .otta/codex.env missing 'legacy' disclaimer comment"
pass "AC1: legacy .otta/codex.env still written with legacy comment"

# ---------------------------------------------------------------------------
# 21. AC2: re-run preserves existing [otel] direct keys, only overwrites otlp-http
# ---------------------------------------------------------------------------
RDIR="$TMP/repo21"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex21"
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<'TOML'
[otel]
log_user_prompt = true
some_custom_key = "user_value"
TOML
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "AC2 preserve run exited non-zero"
grep -q 'log_user_prompt = true' "$CODEX_HOME/config.toml" || \
  fail "AC2: existing [otel] key log_user_prompt=true was clobbered: $(cat "$CODEX_HOME/config.toml")"
grep -q 'some_custom_key = "user_value"' "$CODEX_HOME/config.toml" || \
  fail "AC2: existing [otel] key some_custom_key was clobbered: $(cat "$CODEX_HOME/config.toml")"
grep -q '^\[otel.exporter.otlp-http\]' "$CODEX_HOME/config.toml" || \
  fail "AC2: [otel.exporter.otlp-http] not written after preserve: $(cat "$CODEX_HOME/config.toml")"
pass "AC2: config.toml re-run preserves existing [otel] direct keys"

# ---------------------------------------------------------------------------
# 22. AC2: re-run with different token updates x-pulse-token without duplication
# ---------------------------------------------------------------------------
RDIR="$TMP/repo22"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex22"
mkdir -p "$CODEX_HOME"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "old_token_ABC" || fail "AC2 update run 1 failed"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "new_token_XYZ" || fail "AC2 update run 2 failed"
grep -q 'x-pulse-token = "new_token_XYZ"' "$CODEX_HOME/config.toml" || \
  fail "AC2: new token not reflected in config.toml: $(cat "$CODEX_HOME/config.toml")"
N="$(grep -c 'x-pulse-token' "$CODEX_HOME/config.toml")"
[ "$N" = "2" ] || fail "AC2: x-pulse-token appears $N times in config.toml (expected 2: log + metrics headers)"
pass "AC2: config.toml re-run updates [otel.exporter.otlp-http] without duplication"

# ---------------------------------------------------------------------------
# 23. Bug fix: [otel.metrics_exporter.otlp-http] written with /v1/metrics endpoint
# ---------------------------------------------------------------------------
RDIR="$TMP/repo23"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex23"
mkdir -p "$CODEX_HOME"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "metrics exporter run exited non-zero"
grep -q '^\[otel.metrics_exporter.otlp-http\]' "$CODEX_HOME/config.toml" || \
  fail "Bug2: config.toml missing [otel.metrics_exporter.otlp-http]: $(cat "$CODEX_HOME/config.toml")"
grep -q 'endpoint = "https://pulse.otta.build/v1/metrics"' "$CODEX_HOME/config.toml" || \
  fail "Bug2: metrics endpoint wrong (must be /v1/metrics): $(grep endpoint "$CODEX_HOME/config.toml" || echo not-found)"
grep -q '^\[otel.metrics_exporter.otlp-http.headers\]' "$CODEX_HOME/config.toml" || \
  fail "Bug2: config.toml missing [otel.metrics_exporter.otlp-http.headers]"
grep -q "x-pulse-token = \"$TOKEN\"" "$CODEX_HOME/config.toml" || \
  fail "Bug2: metrics exporter headers missing x-pulse-token"
pass "Bug fix: config.toml [otel.metrics_exporter.otlp-http] with /v1/metrics endpoint + token"

# ---------------------------------------------------------------------------
# 24. AC5: Codex exporter selectors are enabled directly under [otel]
# ---------------------------------------------------------------------------
RDIR="$TMP/repo24"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex24"
mkdir -p "$CODEX_HOME"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "selector run exited non-zero"
[ "$(grep -c '^exporter = "otlp-http"$' "$CODEX_HOME/config.toml")" = "1" ] || \
  fail "AC5: config.toml must contain one exporter = \"otlp-http\" selector under [otel]"
[ "$(grep -c '^metrics_exporter = "otlp-http"$' "$CODEX_HOME/config.toml")" = "1" ] || \
  fail "AC5: config.toml must contain one metrics_exporter = \"otlp-http\" selector under [otel]"
pass "AC5: config.toml enables log and metrics exporters with direct [otel] selectors"

# ---------------------------------------------------------------------------
# 25. AC5: merge replaces disabled selectors, preserves other [otel] keys,
#     accepts quoted managed subtable syntax, and remains byte-stable.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo25"
mkdir -p "$RDIR"
cd "$RDIR"
CODEX_HOME="$TMP/codex25"
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<'TOML'
[model]
name = "gpt-5"

[otel]
exporter = "none"
metrics_exporter = "none"
log_user_prompt = true
environment = "staging"
custom_direct_key = "keep-me"

[otel.exporter."otlp-http"]
endpoint = "https://old.invalid/v1/logs"
protocol = "protobuf"

[otel.exporter."otlp-http".headers]
x-pulse-token = "fixture-old-token"

[otel.metrics_exporter."otlp-http"]
endpoint = "https://old.invalid/v1/metrics"
protocol = "protobuf"

[otel.metrics_exporter."otlp-http".headers]
x-pulse-token = "fixture-old-token"

[history]
persistence = "save-all"
TOML
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "quoted merge run exited non-zero"
CONFIG="$CODEX_HOME/config.toml"
[ "$(grep -c '^exporter = ' "$CONFIG")" = "1" ] || fail "AC5: exporter selector duplicated during merge"
[ "$(grep -c '^metrics_exporter = ' "$CONFIG")" = "1" ] || fail "AC5: metrics selector duplicated during merge"
grep -q '^exporter = "otlp-http"$' "$CONFIG" || fail "AC5: disabled exporter selector was not replaced"
grep -q '^metrics_exporter = "otlp-http"$' "$CONFIG" || fail "AC5: disabled metrics selector was not replaced"
grep -q '^log_user_prompt = true$' "$CONFIG" || fail "AC5: explicit log_user_prompt value was not preserved"
grep -q '^environment = "staging"$' "$CONFIG" || fail "AC5: unrelated environment key was not preserved"
grep -q '^custom_direct_key = "keep-me"$' "$CONFIG" || fail "AC5: unrelated direct [otel] key was not preserved"
grep -q '^\[history\]$' "$CONFIG" || fail "AC5: unrelated table was not preserved"
! grep -q 'old.invalid\|fixture-old-token\|protocol = "protobuf"' "$CONFIG" || \
  fail "AC5: quoted Otta-managed exporter subtables were not replaced"
grep -q '^\[otel.exporter.otlp-http\]$' "$CONFIG" || fail "AC5: supported logs subtable missing"
grep -q '^endpoint = "https://pulse.otta.build/v1/logs"$' "$CONFIG" || fail "AC5: supported logs endpoint missing"
grep -q '^\[otel.metrics_exporter.otlp-http\]$' "$CONFIG" || fail "AC5: supported metrics subtable missing"
grep -q '^endpoint = "https://pulse.otta.build/v1/metrics"$' "$CONFIG" || fail "AC5: supported metrics endpoint missing"
[ "$(grep -c '^protocol = "json"$' "$CONFIG")" = "2" ] || fail "AC5: logs and metrics must keep protocol=json"
[ "$(grep -c '^x-pulse-token = ' "$CONFIG")" = "2" ] || fail "AC5: expected one token header per exporter"
FIRST="$(cat "$CONFIG")"
CODEX_HOME="$CODEX_HOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "quoted merge rerun exited non-zero"
SECOND="$(cat "$CONFIG")"
[ "$FIRST" = "$SECOND" ] || fail "AC5: quoted merge rerun changed config.toml bytes"
[ "$(stat -c '%a' "$CONFIG" 2>/dev/null || stat -f '%Lp' "$CONFIG")" = "600" ] || fail "AC5: config.toml mode is not 600"
pass "AC5: selector merge handles disabled selectors and quoted subtables without clobbering user config"

# ---------------------------------------------------------------------------
# 26. AC5: --derive hosted mode calls /token without auth and writes the
#     derived repo token without printing it.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo26"
mkdir -p "$RDIR" "$TMP/codex26" "$TMP/codex-derive-bin"
cd "$RDIR"
cat > "$TMP/codex-derive-bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGS_FILE"
printf '{"token":"hosted-derived-fixture"}'
CURL_STUB
chmod +x "$TMP/codex-derive-bin/curl"
OUT="$(CURL_ARGS_FILE="$TMP/codex26-curl.txt" PATH="$TMP/codex-derive-bin:$PATH" CODEX_HOME="$TMP/codex26" bash "$SCRIPT" --derive "$REPO_SLUG" 2>&1)" || \
  fail "AC5: hosted --derive run exited non-zero"
grep -q '/token?repo=acme/widget' "$TMP/codex26-curl.txt" || fail "AC5: hosted --derive did not call the repo token endpoint"
! grep -q 'x-pulse-token' "$TMP/codex26-curl.txt" || fail "AC5: hosted --derive must not send a webhook secret"
grep -q 'x-pulse-token = "hosted-derived-fixture"' "$TMP/codex26/config.toml" || fail "AC5: derived token not written to config.toml"
[ "$(grep -c 'x-pulse-repo = "acme/widget"' "$TMP/codex26/config.toml")" = "2" ] || fail "AC5: repo header must be written for logs and metrics"
! printf '%s' "$OUT" | grep -q 'hosted-derived-fixture' || fail "AC5: derived token printed to output"
pass "AC5: hosted --derive obtains a repo token without auth and keeps it private"

# ---------------------------------------------------------------------------
# 27. AC5: --derive self-hosted mode requires and sends the webhook secret,
#     but stores only the derived token.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo27"
mkdir -p "$RDIR" "$TMP/codex27"
cd "$RDIR"
SELFHOST_SECRET="selfhost-webhook-fixture"
OUT="$(CURL_ARGS_FILE="$TMP/codex27-curl.txt" PATH="$TMP/codex-derive-bin:$PATH" CODEX_HOME="$TMP/codex27" OTTA_PULSE_URL="https://pulse.example.test/" bash "$SCRIPT" --derive "$REPO_SLUG" "$SELFHOST_SECRET" 2>&1)" || \
  fail "AC5: self-hosted --derive run exited non-zero"
grep -q 'https://pulse.example.test/token?repo=acme/widget' "$TMP/codex27-curl.txt" || fail "AC5: self-hosted --derive endpoint wrong"
grep -q "x-pulse-token: $SELFHOST_SECRET" "$TMP/codex27-curl.txt" || fail "AC5: self-hosted --derive did not authenticate token derivation"
grep -q 'hosted-derived-fixture' "$TMP/codex27/config.toml" || fail "AC5: self-hosted derived token not stored"
! grep -q "$SELFHOST_SECRET" "$TMP/codex27/config.toml" .otta/codex.env || fail "AC5: webhook secret was stored"
! printf '%s' "$OUT" | grep -q "$SELFHOST_SECRET\|hosted-derived-fixture" || fail "AC5: token or webhook secret printed"
pass "AC5: self-hosted --derive uses the webhook secret only for derivation"

# ---------------------------------------------------------------------------
# 28. AC5: --derive usage guards and token-response redaction.
# ---------------------------------------------------------------------------
if PATH="$TMP/codex-derive-bin:$PATH" bash "$SCRIPT" --derive >/dev/null 2>&1; then
  fail "AC5: --derive without repo must fail"
fi
if OTTA_PULSE_URL="https://pulse.example.test" PATH="$TMP/codex-derive-bin:$PATH" bash "$SCRIPT" --derive "$REPO_SLUG" >/dev/null 2>&1; then
  fail "AC5: self-hosted --derive without webhook secret must fail"
fi
cat > "$TMP/codex-derive-bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
printf '{"error":"denied","token_hint":"response-secret-fixture"}'
CURL_STUB
chmod +x "$TMP/codex-derive-bin/curl"
set +e
ERROR_OUT="$(PATH="$TMP/codex-derive-bin:$PATH" CODEX_HOME="$TMP/codex28" bash "$SCRIPT" --derive "$REPO_SLUG" 2>&1)"
ERROR_RC=$?
set -e
[ "$ERROR_RC" -ne 0 ] || fail "AC5: tokenless derivation response must fail"
! printf '%s' "$ERROR_OUT" | grep -q 'response-secret-fixture' || fail "AC5: token-bearing derivation response leaked"
printf '%s' "$ERROR_OUT" | grep -q 'did not contain a token field' || fail "AC5: redacted derivation error is not actionable"
pass "AC5: --derive validates usage and redacts token-bearing response bodies"

# ---------------------------------------------------------------------------
# 29. AC5: legacy sourceable env shell-quotes hostile values. Newlines,
#     substitutions, quotes, and metacharacters must round-trip without running.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo29"
mkdir -p "$RDIR" "$TMP/codex29"
cd "$RDIR"
MARKER="$TMP/codex-env-injection.marker"
REPO_HOSTILE=$'acme/widget\n; touch "$MARKER" #'
TOKEN_HOSTILE=$'token-line-1\n$(touch "$MARKER") ; `touch "$MARKER"` '\'' " $PATH'
PULSE_HOSTILE=$'https://pulse.example.test/base\n$(touch "$MARKER")'
OUT="$(CODEX_HOME="$TMP/codex29" OTTA_PULSE_URL="$PULSE_HOSTILE" bash "$SCRIPT" "$REPO_HOSTILE" "$TOKEN_HOSTILE" 2>&1)" || \
  fail "AC5: hostile direct-token run exited non-zero"
EXPECTED_REPO="$REPO_HOSTILE" EXPECTED_TOKEN="$TOKEN_HOSTILE" EXPECTED_PULSE="$PULSE_HOSTILE" MARKER="$MARKER" \
  bash -c '
    set -eu
    source "$1"
    [ "$OTEL_RESOURCE_ATTRIBUTES" = "repo=${EXPECTED_REPO},harness=codex" ]
    [ "$OTEL_EXPORTER_OTLP_LOGS_ENDPOINT" = "${EXPECTED_PULSE}/v1/logs" ]
    [ "$OTEL_EXPORTER_OTLP_METRICS_ENDPOINT" = "${EXPECTED_PULSE}/v1/metrics" ]
    [ "$OTEL_EXPORTER_OTLP_LOGS_HEADERS" = "x-pulse-token=${EXPECTED_TOKEN}" ]
    [ "$OTEL_EXPORTER_OTLP_METRICS_HEADERS" = "x-pulse-token=${EXPECTED_TOKEN}" ]
  ' _ .otta/codex.env || fail "AC5: safely quoted legacy values did not round-trip when sourced"
[ ! -e "$MARKER" ] || fail "AC5: sourcing legacy env executed hostile repo/Pulse/token content"
printf '%s' "$OUT" | grep -Eqi 'restart Codex|new Codex process' || fail "AC5: setup output must require a new Codex process"
pass "AC5: legacy env safely round-trips hostile values and setup requires a Codex restart"

# ---------------------------------------------------------------------------
# 30. AC6: README prefers $otta-setup and uses an explicit absolute installed
#     root for normal-shell automation examples.
# ---------------------------------------------------------------------------
README="$HERE/../README.md"
grep -Fq '$otta-setup' "$README" || fail "AC6: README must recommend \$otta-setup"
grep -Fq 'OTTA_PLUGIN_ROOT=/absolute/path/to/installed/otta' "$README" || \
  fail "AC6: README automation must show a user-supplied absolute installed plugin root"
! grep -Fq 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/' "$README" || \
  fail "AC6: README normal-shell examples must not depend on CLAUDE_PLUGIN_ROOT"
! grep -q 'Pulse validates the claimed repo' "$README" || \
  fail "AC6: README must not claim Pulse repo-header validation before it ships"
grep -Eqi 'x-pulse-repo.*required.*contract|required.*contract.*x-pulse-repo' "$README" || \
  fail "AC6: README must describe x-pulse-repo as a required ingestion contract"
pass "AC6: README uses runtime-safe automation paths and accurate repo-header wording"

# ---------------------------------------------------------------------------
# 31. AC5: a quoted literal TOML table name is not the dotted Otta table.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo31"
mkdir -p "$RDIR" "$TMP/codex31"
cd "$RDIR"
cat > "$TMP/codex31/config.toml" <<'TOML'
["otel.exporter.otlp-http"]
literal_table_value = "preserve-me"

["otel.metrics_exporter.otlp-http".headers]
literal_metrics_value = "also-preserve"
TOML
CODEX_HOME="$TMP/codex31" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "AC5: literal quoted table run failed"
grep -q '^\["otel.exporter.otlp-http"\]$' "$TMP/codex31/config.toml" || fail "AC5: literal quoted table header was removed"
grep -q '^literal_table_value = "preserve-me"$' "$TMP/codex31/config.toml" || fail "AC5: literal quoted table content was removed"
grep -q '^\["otel.metrics_exporter.otlp-http".headers\]$' "$TMP/codex31/config.toml" || fail "AC5: literal quoted metrics table was removed"
grep -q '^literal_metrics_value = "also-preserve"$' "$TMP/codex31/config.toml" || fail "AC5: literal quoted metrics content was removed"
grep -q '^\[otel.exporter.otlp-http\]$' "$TMP/codex31/config.toml" || fail "AC5: managed dotted exporter table missing"
pass "AC5: literal quoted TOML tables remain distinct from managed dotted tables"

# ---------------------------------------------------------------------------
# 32. AC5: direct mode prefers OTTA_PULSE_TOKEN so secrets avoid argv/history.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo32"
mkdir -p "$RDIR" "$TMP/codex32"
cd "$RDIR"
ENV_TOKEN="env-direct-token-fixture"
OUT="$(OTTA_PULSE_TOKEN="$ENV_TOKEN" CODEX_HOME="$TMP/codex32" bash "$SCRIPT" "$REPO_SLUG" 2>&1)" || fail "AC5: env-token direct mode failed"
grep -q 'x-pulse-token = "env-direct-token-fixture"' "$TMP/codex32/config.toml" || fail "AC5: OTTA_PULSE_TOKEN was not used"
! printf '%s' "$OUT" | grep -q "$ENV_TOKEN" || fail "AC5: OTTA_PULSE_TOKEN printed to output"
pass "AC5: direct mode accepts OTTA_PULSE_TOKEN without a token argv"

# ---------------------------------------------------------------------------
# 33. AC5: self-hosted derive prefers OTTA_PULSE_WEBHOOK_SECRET.
# ---------------------------------------------------------------------------
RDIR="$TMP/repo33"
mkdir -p "$RDIR" "$TMP/codex33" "$TMP/codex33-bin"
cd "$RDIR"
cat > "$TMP/codex33-bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGS_FILE"
printf '{"token":"env-derived-token-fixture"}'
CURL_STUB
chmod +x "$TMP/codex33-bin/curl"
ENV_WEBHOOK="env-webhook-secret-fixture"
OUT="$(CURL_ARGS_FILE="$TMP/codex33-curl.txt" PATH="$TMP/codex33-bin:$PATH" CODEX_HOME="$TMP/codex33" OTTA_PULSE_URL="https://pulse.example.test" OTTA_PULSE_WEBHOOK_SECRET="$ENV_WEBHOOK" bash "$SCRIPT" --derive "$REPO_SLUG" 2>&1)" || fail "AC5: env-secret self-hosted derive failed"
grep -q "x-pulse-token: $ENV_WEBHOOK" "$TMP/codex33-curl.txt" || fail "AC5: OTTA_PULSE_WEBHOOK_SECRET was not used for derivation"
! grep -q "$ENV_WEBHOOK" "$TMP/codex33/config.toml" .otta/codex.env || fail "AC5: webhook secret was stored"
! printf '%s' "$OUT" | grep -q "$ENV_WEBHOOK\|env-derived-token-fixture" || fail "AC5: derivation secret/token printed"
pass "AC5: self-hosted derive accepts OTTA_PULSE_WEBHOOK_SECRET without secret argv"

# ---------------------------------------------------------------------------
# 34. AC6: docs prefer secret environment variables and disclose local tokens.
# ---------------------------------------------------------------------------
grep -q 'OTTA_PULSE_TOKEN' "$README" || fail "AC6: README must document OTTA_PULSE_TOKEN"
grep -q 'OTTA_PULSE_WEBHOOK_SECRET' "$README" || fail "AC6: README must document OTTA_PULSE_WEBHOOK_SECRET"
grep -Eqi 'legacy positional|positional.*legacy' "$README" || fail "AC6: positional secret compatibility must be labeled legacy"
grep -Eqi 'opt.in.*local.*repo token|local.*repo token.*opt.in' "$README" || fail "AC6: README must disclose opt-in local repo tokens"
pass "AC6: README prefers environment secrets and scopes Pulse communication accurately"

echo "All otta-codex-setup tests passed."
