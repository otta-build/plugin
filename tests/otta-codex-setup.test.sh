#!/usr/bin/env bash
# otta-codex-setup.test.sh — regression tests for scripts/otta-codex-setup.sh (issue #30).
# Writes .otta/codex.env with standard OTEL env vars; never uses TOML; gitignored; idempotent.
# Run: bash tests/otta-codex-setup.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-codex-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

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
# 8. AC3: output includes sourcing instructions
# ---------------------------------------------------------------------------
RDIR="$TMP/repo8"
mkdir -p "$RDIR"
cd "$RDIR"
OUT="$(bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" 2>&1)"
echo "$OUT" | grep -qi 'source' || fail "AC3: sourcing instructions missing from output"
pass "AC3: sourcing instructions included in output"

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

echo "All otta-codex-setup tests passed."
