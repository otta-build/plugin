#!/usr/bin/env bash
# otta-gemini-setup.test.sh — regression tests for scripts/otta-gemini-setup.sh (issue #30).
# Writes .gemini/settings.json + otel-collector-config.yaml for sidecar-based telemetry.
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
# 1. Basic write: .gemini/settings.json and otel-collector-config.yaml created
# ---------------------------------------------------------------------------
RDIR="$TMP/repo1"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "basic run exited non-zero"
[ -f ".gemini/settings.json" ] || fail ".gemini/settings.json not created"
[ -f "otel-collector-config.yaml" ] || fail "otel-collector-config.yaml not created"
valid_json ".gemini/settings.json" || fail ".gemini/settings.json is not valid JSON"
pass "AC2: settings.json and otel-collector-config.yaml created"

# ---------------------------------------------------------------------------
# 2. settings.json: telemetry.endpoint points at local collector
# ---------------------------------------------------------------------------
RDIR="$TMP/repo2"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "settings run exited non-zero"
ENDPOINT="$(getjson ".gemini/settings.json" "telemetry.endpoint")"
[ "$ENDPOINT" = "http://localhost:4318/v1/logs" ] || \
  fail "telemetry.endpoint wrong: $ENDPOINT"
pass "AC2: telemetry.endpoint = http://localhost:4318/v1/logs"

# ---------------------------------------------------------------------------
# 3. collector config: has required sections (receivers, processors, exporters)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo3"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "collector config run exited non-zero"
YAML="otel-collector-config.yaml"
grep -q 'receivers:' "$YAML" || fail "collector yaml: missing receivers"
grep -q 'processors:' "$YAML" || fail "collector yaml: missing processors"
grep -q 'exporters:' "$YAML" || fail "collector yaml: missing exporters"
grep -q '4318' "$YAML" || fail "collector yaml: missing port 4318 (otlp http)"
pass "AC2: collector yaml has receivers/processors/exporters + port 4318"

# ---------------------------------------------------------------------------
# 4. collector config: repo + harness=gemini resource attrs
# ---------------------------------------------------------------------------
RDIR="$TMP/repo4"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "attrs run exited non-zero"
YAML="otel-collector-config.yaml"
grep -q "$REPO_SLUG" "$YAML" || fail "collector yaml: repo slug not present"
grep -q 'harness' "$YAML" || fail "collector yaml: harness attr not present"
grep -q 'gemini' "$YAML" || fail "collector yaml: gemini value not present"
pass "AC2: collector yaml contains repo and harness=gemini attrs"

# ---------------------------------------------------------------------------
# 5. collector config: x-pulse-token uses env substitution (NOT literal token)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo5"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "token-safety run exited non-zero"
YAML="otel-collector-config.yaml"
# Token must NOT appear literally in the yaml (it uses env substitution)
grep -q "$TOKEN" "$YAML" && fail "literal token present in collector yaml (should use env substitution)"
# But env substitution pattern should be present
grep -q 'OTTA_PULSE_TOKEN\|env:' "$YAML" || fail "collector yaml: missing env substitution for token"
pass "AC5: token uses env substitution in collector yaml (not literal)"

# ---------------------------------------------------------------------------
# 6. collector config: cost_usd transform present
# ---------------------------------------------------------------------------
RDIR="$TMP/repo6"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "cost_usd run exited non-zero"
grep -q 'cost_usd' "otel-collector-config.yaml" || fail "collector yaml: cost_usd not present"
pass "AC2: collector yaml includes cost_usd computation"

# ---------------------------------------------------------------------------
# 7. collector config: pulse export URL — base only (otlphttp appends /v1/logs)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo7"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "default pulse URL run failed"
# Exporter endpoint must be the base URL only. The otlphttp exporter appends
# /v1/logs automatically; including /v1 in the config would produce /v1/v1/logs.
grep -q 'endpoint: "https://pulse.otta.build"' "otel-collector-config.yaml" || \
  fail "exporter endpoint must be bare base URL (without /v1), got: $(grep 'endpoint' otel-collector-config.yaml | tail -1)"
# And must NOT have the doubled path
grep -v '#' "otel-collector-config.yaml" | grep 'endpoint' | grep -v 'localhost' | grep -q '/v1"' && \
  fail "exporter endpoint contains /v1 — would double to /v1/v1/logs" || true
RDIR="$TMP/repo7b"
mkdir -p "$RDIR"
cd "$RDIR"
OTTA_PULSE_URL="https://pulse.acme.example/" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || \
  fail "override pulse URL run failed"
grep -q 'endpoint: "https://pulse.acme.example"' "otel-collector-config.yaml" || \
  fail "override pulse URL endpoint wrong: $(grep 'endpoint' otel-collector-config.yaml | tail -1)"
pass "AC1: pulse URL base-only in exporter endpoint (default + OTTA_PULSE_URL override)"

# ---------------------------------------------------------------------------
# 8. Merge: pre-existing settings.json keys preserved (idempotent JSON merge)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo8"
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
[ "$(getjson ".gemini/settings.json" "telemetry.endpoint")" = "http://localhost:4318/v1/logs" ] || \
  fail "merge: telemetry.endpoint not merged"
pass "AC4: merge preserves pre-existing settings.json keys"

# ---------------------------------------------------------------------------
# 9. Idempotent: re-run produces byte-identical output
# ---------------------------------------------------------------------------
RDIR="$TMP/repo9"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent run 1 failed"
FIRST_SETTINGS="$(cat .gemini/settings.json)"
FIRST_YAML="$(cat otel-collector-config.yaml)"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent run 2 failed"
SECOND_SETTINGS="$(cat .gemini/settings.json)"
SECOND_YAML="$(cat otel-collector-config.yaml)"
[ "$FIRST_SETTINGS" = "$SECOND_SETTINGS" ] || fail "settings.json not idempotent on re-run"
[ "$FIRST_YAML" = "$SECOND_YAML" ] || fail "otel-collector-config.yaml not idempotent on re-run"
pass "AC4: idempotent re-run (stable output for both files)"

# ---------------------------------------------------------------------------
# 10. .gitignore: .gemini/settings.json added (idempotent)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo10"
mkdir -p "$RDIR"
cd "$RDIR"
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "gitignore run failed"
grep -qF '.gemini/settings.json' ".gitignore" || fail ".gitignore: .gemini/settings.json not added"
# Re-run does not duplicate
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "gitignore idempotent run failed"
N="$(grep -c '\.gemini/settings\.json' ".gitignore")"
[ "$N" = "1" ] || fail ".gitignore: pattern duplicated after re-run (count=$N)"
pass "AC2: .gitignore updated with .gemini/settings.json (idempotent)"

# ---------------------------------------------------------------------------
# 11. Token not staged: literal token not in any git-staged file
# ---------------------------------------------------------------------------
RDIR="$TMP/repo11"
mkdir -p "$RDIR"
cd "$RDIR"
git init -q -b main
git config user.email t@t.t
git config user.name t
bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "token-staged run failed"
git add -A
# The literal token must not appear in any staged file
STAGED_WITH_TOKEN="$(git diff --cached --name-only | while read -r f; do
  grep -q "$TOKEN" "$f" 2>/dev/null && echo "$f" || true
done)"
[ -z "$STAGED_WITH_TOKEN" ] || fail "literal token found in staged file(s): $STAGED_WITH_TOKEN"
pass "AC5: literal token not in any staged file"

# ---------------------------------------------------------------------------
# 12. AC3: consent disclosure + sidecar start instructions
# ---------------------------------------------------------------------------
RDIR="$TMP/repo12"
mkdir -p "$RDIR"
cd "$RDIR"
OUT="$(bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" 2>&1)"
echo "$OUT" | grep -q 'pulse.otta.build' || fail "AC3: consent disclosure missing pulse.otta.build"
echo "$OUT" | grep -qi 'docker\|collector' || fail "AC2: sidecar start instructions missing"
pass "AC3: consent disclosure + sidecar start instructions printed"

# ---------------------------------------------------------------------------
# 13. Usage guard: missing args exit non-zero
# ---------------------------------------------------------------------------
RDIR="$TMP/repo13"
mkdir -p "$RDIR"
cd "$RDIR"
if bash "$SCRIPT" >/dev/null 2>&1; then fail "missing args should exit non-zero"; fi
if bash "$SCRIPT" "$REPO_SLUG" >/dev/null 2>&1; then fail "missing token should exit non-zero"; fi
pass "usage guard: missing repo/token rejected"

echo "All otta-gemini-setup tests passed."
