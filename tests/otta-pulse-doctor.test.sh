#!/usr/bin/env bash
# otta-pulse-doctor.test.sh — regression tests for scripts/otta-pulse-doctor.sh.
# Run: bash tests/otta-pulse-doctor.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-pulse-doctor.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$SCRIPT" ] || fail "script not found at $SCRIPT"
command -v jq >/dev/null || fail "jq required to run this test"

# ---------------------------------------------------------------------------
# 1. Missing GitHub App credentials fails with an actionable auth-type message.
# ---------------------------------------------------------------------------
OUT="$("$SCRIPT" acme/widget 2>&1 || true)"
echo "$OUT" | grep -q "GitHub App credentials required" || \
  fail "missing credentials output should explain App JWT creds, got: $OUT"
echo "$OUT" | grep -q "user token" || \
  fail "missing credentials output should mention a gh user token is not enough, got: $OUT"
pass "missing App credentials fail with actionable auth guidance"

# ---------------------------------------------------------------------------
# 2. Happy path uses App JWT auth, mints installation token, and validates
#    checks:write without printing the installation token.
# ---------------------------------------------------------------------------
BIN="$TMP/bin"
mkdir -p "$BIN"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo "acme/widget"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 9
SH
chmod +x "$BIN/gh"

cat > "$BIN/openssl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf 'fake-signature'
SH
chmod +x "$BIN/openssl"

CALLS="$TMP/curl-calls.log"
cat > "$BIN/curl" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$CALLS"
case " \$* " in
  *"/app "*)
    printf '%s\n' '{"slug":"otta-pulse","permissions":{"checks":"write"}}'
    ;;
  *"/repos/acme/widget/installation "*)
    printf '%s\n' '{"id":12345,"app_slug":"otta-pulse","target_type":"Organization"}'
    ;;
  *"/app/installations/12345/access_tokens "*)
    printf '%s\n' '{"token":"installation_token_SECRET","permissions":{"checks":"write","metadata":"read"},"repositories":[{"full_name":"acme/widget"}]}'
    ;;
  *)
    echo "unexpected curl invocation: \$*" >&2
    exit 8
    ;;
esac
SH
chmod +x "$BIN/curl"

PRIVATE_KEY_FILE="$TMP/app.pem"
printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'fake' '-----END PRIVATE KEY-----' > "$PRIVATE_KEY_FILE"

OUT="$(
  PATH="$BIN:$PATH" \
  OTTA_PULSE_APP_ID="123" \
  OTTA_PULSE_PRIVATE_KEY_PATH="$PRIVATE_KEY_FILE" \
  "$SCRIPT" 2>&1
)" || fail "happy path exited non-zero: $OUT"

echo "$OUT" | grep -q "Pulse app: otta-pulse" || fail "output missing app slug: $OUT"
echo "$OUT" | grep -q "Repo installation: acme/widget" || fail "output missing repo installation: $OUT"
echo "$OUT" | grep -q "checks: write" || fail "output missing checks: write: $OUT"
echo "$OUT" | grep -q "OK: Otta Pulse can post GitHub Check Runs" || fail "output missing OK verdict: $OUT"
if echo "$OUT" | grep -q "installation_token_SECRET"; then
  fail "doctor leaked installation token in output: $OUT"
fi
grep -q "Authorization: Bearer" "$CALLS" || fail "curl calls did not use Bearer auth"
pass "happy path validates checks:write with App JWT and redacts tokens"

# ---------------------------------------------------------------------------
# 3. checks:read fails with a clear next action.
# ---------------------------------------------------------------------------
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *"/app "*)
    printf '%s\n' '{"slug":"otta-pulse","permissions":{"checks":"read"}}'
    ;;
  *"/repos/acme/widget/installation "*)
    printf '%s\n' '{"id":12345,"app_slug":"otta-pulse","target_type":"Organization"}'
    ;;
  *"/app/installations/12345/access_tokens "*)
    printf '%s\n' '{"token":"installation_token_SECRET","permissions":{"checks":"read","metadata":"read"}}'
    ;;
  *)
    echo "unexpected curl invocation: $*" >&2
    exit 8
    ;;
esac
SH
chmod +x "$BIN/curl"

OUT="$(
  PATH="$BIN:$PATH" \
  OTTA_PULSE_APP_ID="123" \
  OTTA_PULSE_PRIVATE_KEY_PATH="$PRIVATE_KEY_FILE" \
  "$SCRIPT" acme/widget 2>&1
)" && fail "checks:read should fail, got success: $OUT"

echo "$OUT" | grep -q "checks: read" || fail "checks:read output missing actual permission: $OUT"
echo "$OUT" | grep -q "Update the GitHub App permission to Checks: Read and write" || \
  fail "checks:read output missing repair instruction: $OUT"
pass "checks:read fails with repair instruction"
