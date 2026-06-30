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
grep -q "OTEL_RESOURCE_ATTRIBUTES=repo=$REPO_SLUG,harness=codex" ".otta/codex.env" || \
  fail "OTEL_RESOURCE_ATTRIBUTES with repo+harness=codex not found: $(cat .otta/codex.env)"
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
if bash "$SCRIPT" "$REPO_SLUG" >/dev/null 2>&1; then fail "missing token should exit non-zero"; fi
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
grep -q 'endpoint = "https://pulse.otta.build"' "$CODEX_HOME/config.toml" || \
  fail "config.toml endpoint wrong (must be base URL, no /v1 path): $(grep endpoint "$CODEX_HOME/config.toml" || echo not-found)"
grep -q 'protocol = "json"' "$CODEX_HOME/config.toml" || \
  fail "config.toml missing protocol = \"json\""
pass "AC1: config.toml [otel.exporter.otlp-http] with base endpoint + protocol=json"

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
grep -q 'endpoint = "https://pulse.acme.example"' "$CODEX_HOME/config.toml" || \
  fail "OTTA_PULSE_URL override not reflected in config.toml: $(grep endpoint "$CODEX_HOME/config.toml" || echo not-found)"
pass "AC1: OTTA_PULSE_URL override (trailing slash normalized) in config.toml"

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
[ "$N" = "1" ] || fail "AC2: x-pulse-token appears $N times in config.toml (expected 1)"
pass "AC2: config.toml re-run updates [otel.exporter.otlp-http] without duplication"

echo "All otta-codex-setup tests passed."
