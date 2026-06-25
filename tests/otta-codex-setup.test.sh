#!/usr/bin/env bash
# otta-codex-setup.test.sh — regression tests for scripts/otta-codex-setup.sh (issue #30).
# Writes [otel] table to ~/.codex/config.toml; merges, never clobbers; idempotent; gitignored.
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

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required"; exit 0; }

# ---------------------------------------------------------------------------
# Helper: read a key from the [otel] section of a TOML file
# ---------------------------------------------------------------------------
getotel() { # <file> <key>
  python3 -c "
import sys
path, key = sys.argv[1], sys.argv[2]
in_otel = False
try:
    with open(path) as f:
        for line in f:
            line = line.rstrip()
            if line.startswith('['):
                in_otel = (line.strip() == '[otel]')
            elif in_otel and line.startswith(key + ' '):
                val = line.split('=', 1)[1].strip().strip('\"')
                print(val)
                sys.exit(0)
except FileNotFoundError:
    pass
print('')
" "$1" "$2"
}

# ---------------------------------------------------------------------------
# 1. Basic write: [otel] section created, required keys present, exits 0
# ---------------------------------------------------------------------------
THOME="$TMP/home1"
mkdir -p "$THOME"
HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "basic run exited non-zero"
CONFIG="$THOME/.codex/config.toml"
[ -f "$CONFIG" ] || fail "config.toml not created"
grep -q '\[otel\]' "$CONFIG" || fail "[otel] section not present"
[ "$(getotel "$CONFIG" logs_endpoint)" = "https://pulse.otta.build/v1/logs" ] || \
  fail "logs_endpoint wrong: $(getotel "$CONFIG" logs_endpoint)"
[ "$(getotel "$CONFIG" headers)" = "x-pulse-token=$TOKEN" ] || \
  fail "headers wrong: $(getotel "$CONFIG" headers)"
[ "$(getotel "$CONFIG" resource_attributes)" = "repo=$REPO_SLUG,harness=codex" ] || \
  fail "resource_attributes wrong: $(getotel "$CONFIG" resource_attributes)"
pass "AC1: [otel] section written with correct keys"

# ---------------------------------------------------------------------------
# 2. OTTA_PULSE_URL override (self-host), trailing slash normalized
# ---------------------------------------------------------------------------
THOME="$TMP/home2"
mkdir -p "$THOME"
OTTA_PULSE_URL="https://pulse.acme.example/" HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || \
  fail "self-host run exited non-zero"
CONFIG="$THOME/.codex/config.toml"
[ "$(getotel "$CONFIG" logs_endpoint)" = "https://pulse.acme.example/v1/logs" ] || \
  fail "self-host logs_endpoint wrong: $(getotel "$CONFIG" logs_endpoint)"
pass "AC1: OTTA_PULSE_URL override respected (trailing slash normalized)"

# ---------------------------------------------------------------------------
# 3. Merge: pre-existing [otel] key not owned by us is preserved;
#    pre-existing unrelated section not clobbered; [otel] keys updated
# ---------------------------------------------------------------------------
THOME="$TMP/home3"
mkdir -p "$THOME/.codex"
CONFIG="$THOME/.codex/config.toml"
cat > "$CONFIG" <<'TOML'
[model]
name = "gpt-4o"

[otel]
logs_endpoint = "https://old.example.com/v1/logs"
headers = "x-old-token=oldval"
resource_attributes = "repo=old/repo,harness=codex"
my_extra_key = "keep-me"
TOML
HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "merge run exited non-zero"
# Updated keys
[ "$(getotel "$CONFIG" logs_endpoint)" = "https://pulse.otta.build/v1/logs" ] || \
  fail "merge: logs_endpoint not updated"
[ "$(getotel "$CONFIG" headers)" = "x-pulse-token=$TOKEN" ] || \
  fail "merge: headers not updated"
# Extra key inside [otel] preserved
[ "$(getotel "$CONFIG" my_extra_key)" = "keep-me" ] || \
  fail "merge: my_extra_key inside [otel] was clobbered"
# Unrelated section still present
grep -q '\[model\]' "$CONFIG" || fail "merge: [model] section lost"
grep -q 'name = "gpt-4o"' "$CONFIG" || fail "merge: model.name lost"
pass "AC4: merge preserves pre-existing keys (unrelated section + extra [otel] key)"

# ---------------------------------------------------------------------------
# 4. Idempotent: re-run produces byte-identical output; no duplicate [otel]
# ---------------------------------------------------------------------------
THOME="$TMP/home4"
mkdir -p "$THOME"
HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent run 1 failed"
CONFIG="$THOME/.codex/config.toml"
FIRST="$(cat "$CONFIG")"
HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "idempotent run 2 failed"
SECOND="$(cat "$CONFIG")"
[ "$FIRST" = "$SECOND" ] || fail "re-run changed output (not idempotent)"
# No duplicate [otel] section
N="$(grep -c '\[otel\]' "$CONFIG")"
[ "$N" = "1" ] || fail "duplicate [otel] section: appears $N times"
pass "AC4: idempotent re-run (stable, no dupes)"

# ---------------------------------------------------------------------------
# 5. Gitignore: ~/.gitignore_global gets .codex/config.toml added (once)
# ---------------------------------------------------------------------------
THOME="$TMP/home5"
mkdir -p "$THOME"
GITIGNORE="$THOME/.gitignore_global"
printf '# existing\n' > "$GITIGNORE"
HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "gitignore run failed"
grep -qF '.codex/config.toml' "$GITIGNORE" || fail "gitignore: pattern not added to .gitignore_global"
# Re-run does not duplicate the pattern
HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" || fail "gitignore idempotent run failed"
N="$(grep -c '\.codex/config\.toml' "$GITIGNORE")"
[ "$N" = "1" ] || fail "gitignore: pattern duplicated after re-run (count=$N)"
pass "AC1: .gitignore_global updated (idempotent)"

# ---------------------------------------------------------------------------
# 6. No .gitignore_global: script warns but still exits 0
# ---------------------------------------------------------------------------
THOME="$TMP/home6"
mkdir -p "$THOME"
OUT="$(HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" 2>&1)" || fail "no-gitignore run exited non-zero"
echo "$OUT" | grep -qi "warn\|gitignore\|manual" || \
  fail "no-gitignore: expected a warning in output, got: $OUT"
pass "AC1: no .gitignore_global warns gracefully (exit 0)"

# ---------------------------------------------------------------------------
# 7. AC3: consent disclosure mentions pulse.otta.build
# ---------------------------------------------------------------------------
THOME="$TMP/home7"
mkdir -p "$THOME"
OUT="$(HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" "$TOKEN" 2>&1)"
echo "$OUT" | grep -q 'pulse.otta.build' || fail "AC3: consent disclosure missing pulse.otta.build"
pass "AC3: consent disclosure includes pulse.otta.build"

# ---------------------------------------------------------------------------
# 8. Usage guard: missing args exit non-zero
# ---------------------------------------------------------------------------
THOME="$TMP/home8"
mkdir -p "$THOME"
if HOME="$THOME" bash "$SCRIPT" >/dev/null 2>&1; then fail "missing args should exit non-zero"; fi
if HOME="$THOME" bash "$SCRIPT" "$REPO_SLUG" >/dev/null 2>&1; then fail "missing token should exit non-zero"; fi
pass "usage guard: missing repo/token rejected"

echo "All otta-codex-setup tests passed."
