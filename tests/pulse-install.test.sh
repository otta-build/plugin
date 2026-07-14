#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/pulse-install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

make_repo() {
  local repo="$TMP/$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  printf '%s\n' "$repo"
}

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "repo view --json nameWithOwner -q .nameWithOwner") printf '%s\n' 'acme/widget' ;;
  "auth token") printf '%s\n' 'github-user-token' ;;
  *) exit 9 ;;
esac
SH
chmod +x "$BIN/gh"

write_curl() { cat > "$BIN/curl"; chmod +x "$BIN/curl"; }

write_curl <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *'/connect'*) printf '%s\n200' '{"url":"https://pulse.otta.build","token":"repo-token"}' ;;
  *'/installation-status'*)
    count=0
    [ -f "$STATUS_COUNT_FILE" ] && count="$(cat "$STATUS_COUNT_FILE")"
    count=$((count + 1))
    printf '%s' "$count" > "$STATUS_COUNT_FILE"
    if [ "$count" -eq 1 ]; then
      printf '%s\n200' '{"repo":"acme/widget","state":"not_installed","repositoryAccess":false,"checksWrite":false}'
    else
      printf '%s\n200' '{"repo":"acme/widget","state":"ready","repositoryAccess":true,"checksWrite":true}'
    fi
    ;;
  *) exit 8 ;;
esac
SH
R="$(make_repo ready)"
CURL_LOG="$TMP/ready.log" STATUS_COUNT_FILE="$TMP/ready-count" PATH="$BIN:$PATH" \
  OTTA_PULSE_STATUS_ATTEMPTS=2 OTTA_PULSE_STATUS_INTERVAL_SECONDS=0 \
  bash -c 'cd "$1" && bash "$2"' _ "$R" "$SCRIPT" >"$TMP/ready.out" 2>&1 \
  || fail "ready installation should pass: $(cat "$TMP/ready.out")"
grep -q 'Pulse installation verified' "$TMP/ready.out" || fail "ready output missing verified verdict"
grep -q 'x-pulse-token: repo-token' "$TMP/ready.log" || fail "status request did not use repo-scoped token"
[ "$(cat "$TMP/ready-count")" = 2 ] || fail "setup did not poll through initial not_installed status"
pass "setup polls through not_installed until browser consent becomes ready"

assert_definitive_failure() {
  local state="$1" expected="$2"
  write_curl <<SH
#!/usr/bin/env bash
case "\$*" in
  *'/connect'*) printf '%s\\n200' '{"url":"https://pulse.otta.build","token":"repo-token"}' ;;
  *'/installation-status'*) printf '%s\\n200' '{"repo":"acme/widget","state":"$state","repositoryAccess":false,"checksWrite":false}' ;;
  *) exit 8 ;;
esac
SH
  local repo out rc
  repo="$(make_repo "$state")"
  set +e
  out="$(PATH="$BIN:$PATH" OTTA_PULSE_STATUS_ATTEMPTS=1 bash -c 'cd "$1" && bash "$2"' _ "$repo" "$SCRIPT" 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$state should fail setup"
  printf '%s' "$out" | grep -Eqi "$expected" || fail "$state output missing '$expected': $out"
}

assert_definitive_failure not_installed 'not installed|does not have access'
pass "missing installation fails clearly"
assert_definitive_failure permission_approval_required 'Checks: Read and write|re-accept'
pass "stale checks permission fails clearly"

write_curl <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'/connect'*) printf '%s\n200' '{"url":"https://pulse.otta.build","token":"repo-token"}' ;;
  *'/installation-status'*) printf '%s\n502' '{"repo":"acme/widget","state":"github_unavailable","repositoryAccess":false,"checksWrite":false}' ;;
  *) exit 8 ;;
esac
SH
R="$(make_repo unavailable)"
OUT="$(PATH="$BIN:$PATH" OTTA_PULSE_STATUS_ATTEMPTS=1 bash -c 'cd "$1" && bash "$2"' _ "$R" "$SCRIPT" 2>&1)" \
  || fail "temporary status outage should fail open: $OUT"
printf '%s' "$OUT" | grep -qi 'verification unavailable' || fail "outage warning missing: $OUT"
! printf '%s' "$OUT" | grep -q 'installation verified' || fail "outage falsely claimed verified"
[ -f "$R/.otta/pulse.env" ] || fail "fail-open path did not preserve pulse.env"
pass "temporary status outage fails open without a false connected claim"

# A self-hosted endpoint must survive the human-confirmation boundary. Execute
# instructions/open and verify in separate clean shells with no inherited
# OTTA_PULSE_URL/PULSE_URL, passing only the explicit script option.
SELF_HOSTED_URL="https://pulse.customer.example"
write_curl <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *'/connect'*) printf '%s\n200' '{"url":"https://pulse.customer.example","token":"repo-token"}' ;;
  *'/installation-status'*) printf '%s\n200' '{"repo":"acme/widget","state":"ready","repositoryAccess":true,"checksWrite":true}' ;;
  *) exit 8 ;;
esac
SH
cat > "$BIN/open" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPEN_LOG"
SH
chmod +x "$BIN/open"
R="$(make_repo self-hosted-boundary)"
env -i PATH="$BIN:$PATH" HOME="$HOME" OPEN_LOG="$TMP/open.log" \
  bash -c 'cd "$1" && bash "$2" --pulse-url "$3" --open --instructions-only' \
  _ "$R" "$SCRIPT" "$SELF_HOSTED_URL" >/dev/null 2>&1 \
  || fail "self-hosted instructions call failed"
env -i PATH="$BIN:$PATH" HOME="$HOME" CURL_LOG="$TMP/self-hosted.log" \
  OTTA_PULSE_STATUS_ATTEMPTS=1 \
  bash -c 'cd "$1" && bash "$2" --pulse-url "$3" --verify' \
  _ "$R" "$SCRIPT" "$SELF_HOSTED_URL" >/dev/null 2>&1 \
  || fail "self-hosted verify call failed"
grep -q "${SELF_HOSTED_URL}/connect" "$TMP/self-hosted.log" \
  || fail "verify did not use the explicit self-hosted connect URL"
grep -q "${SELF_HOSTED_URL}/installation-status" "$TMP/self-hosted.log" \
  || fail "status polling did not stay on the explicit self-hosted URL"
! grep -q 'pulse.otta.build' "$TMP/self-hosted.log" \
  || fail "separate-shell self-hosted flow silently fell back to hosted Pulse"
pass "self-hosted URL survives instructions -> confirmation -> verify across clean shells"

echo "All pulse-install tests passed."
