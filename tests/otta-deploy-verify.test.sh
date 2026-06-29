#!/usr/bin/env bash
# otta-deploy-verify.test.sh — regression tests for the deploy+verify stage (#20).
# Covers AC6: policy parsing (each `auto` value), absent block → human-approve,
# prod + merge-and-deploy without opt-in is rejected, gate-poll stall surfaces
# the blocking sub-check, SHA-match pass/fail, and default never-merges.
#
# Self-contained: sources the script's pure functions and feeds fixtures — no
# live `gh`/Coolify call. Pattern matches tests/check-test-coverage-no-origin.test.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-deploy-verify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 — expected [$2], got [$3]"; fail=$((fail+1)); fi; }

[ -f "$SCRIPT" ] || { echo "✗ script not found: $SCRIPT" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SCRIPT"

echo "otta-deploy-verify:"

# ---------------------------------------------------------------------------
# 1. Policy parsing — each `auto` value round-trips
# ---------------------------------------------------------------------------
mk_yml() { f="$TMP/$1.yml"; printf '%s\n' "$2" > "$f"; echo "$f"; }

Y="$(mk_yml ha 'deploy:
  auto: human-approve
  target: staging
  provider: none
  verify: none')"
check "parse auto=human-approve" "human-approve" "$(parse_deploy_auto "$Y")"
check "parse target=staging"     "staging"       "$(parse_deploy_target "$Y")"
check "parse provider=none"      "none"          "$(parse_deploy_provider "$Y")"
check "parse verify=none"        "none"          "$(parse_deploy_verify "$Y")"

Y="$(mk_yml mog 'deploy:
  auto: merge-on-green
  target: staging
  provider: coolify
  verify: sha-match')"
check "parse auto=merge-on-green" "merge-on-green" "$(parse_deploy_auto "$Y")"
check "parse provider=coolify"    "coolify"        "$(parse_deploy_provider "$Y")"
check "parse verify=sha-match"    "sha-match"      "$(parse_deploy_verify "$Y")"

Y="$(mk_yml mad 'deploy:
  auto: merge-and-deploy
  target: production
  provider: coolify
  verify: health
  allow_production: true')"
check "parse auto=merge-and-deploy" "merge-and-deploy" "$(parse_deploy_auto "$Y")"
check "parse target=production"     "production"       "$(parse_deploy_target "$Y")"
check "parse verify=health"         "health"           "$(parse_deploy_verify "$Y")"
check "parse allow_production=true" "true"             "$(parse_deploy_allow_production "$Y")"

# ---------------------------------------------------------------------------
# 2. Absent deploy block → human-approve (back-compat — the load-bearing default)
# ---------------------------------------------------------------------------
Y="$(mk_yml legacy 'base: "main"
staging: null
ci:
  required: true')"
check "absent deploy block → human-approve" "human-approve" "$(parse_deploy_auto "$Y")"
check "absent → target defaults production" "production"     "$(parse_deploy_target "$Y")"
check "absent → provider defaults none"     "none"           "$(parse_deploy_provider "$Y")"
check "absent → allow_production false"      "false"          "$(parse_deploy_allow_production "$Y")"

# Missing file entirely → still human-approve.
check "missing .otta.yml → human-approve" "human-approve" "$(parse_deploy_auto "$TMP/nope.yml")"

# Unknown auto value → safe default.
Y="$(mk_yml bogus 'deploy:
  auto: yolo-ship-it')"
check "unknown auto value → human-approve" "human-approve" "$(parse_deploy_auto "$Y")"

# ---------------------------------------------------------------------------
# 3. decide_merge — the policy table
# ---------------------------------------------------------------------------
# human-approve NEVER merges, even when green.
check "human-approve + green → no-merge" "no-merge" "$(decide_merge human-approve true staging false)"
# default (absent) is human-approve → never merges.
check "default never merges"             "no-merge" "$(decide_merge human-approve true production false)"

# merge-on-green: merge only when green.
check "merge-on-green + green → merge"        "merge"    "$(decide_merge merge-on-green true staging false)"
check "merge-on-green + NOT green → no-merge" "no-merge" "$(decide_merge merge-on-green false staging false)"

# merge-and-deploy to staging needs no opt-in.
check "merge-and-deploy staging + green → merge" "merge" "$(decide_merge merge-and-deploy true staging false)"

# AC5: merge-and-deploy to production WITHOUT opt-in → blocked-prod, even green.
check "AC5 prod + merge-and-deploy, no opt-in → blocked-prod" "blocked-prod" "$(decide_merge merge-and-deploy true production false)"
# With opt-in → merge.
check "prod + merge-and-deploy + opt-in + green → merge" "merge" "$(decide_merge merge-and-deploy true production true)"
# Opt-in but not green → still no merge.
check "prod + merge-and-deploy + opt-in + NOT green → no-merge" "no-merge" "$(decide_merge merge-and-deploy false production true)"

# decide_merge exit code matches (0 only for merge).
decide_merge human-approve true staging false >/dev/null; check "decide_merge no-merge → exit 1" 1 "$?"
decide_merge merge-on-green true staging false >/dev/null; check "decide_merge merge → exit 0" 0 "$?"

# ---------------------------------------------------------------------------
# 4. sha_match — pass / fail
# ---------------------------------------------------------------------------
sha_match abc123def abc123def; check "sha_match identical → 0" 0 "$?"
sha_match abc123def4567 abc123d;  check "sha_match short-prefix → 0" 0 "$?"
sha_match abc123d abc123def4567;  check "sha_match prefix either way → 0" 0 "$?"
sha_match abc123 def456;          check "sha_match different → 1" 1 "$?"
sha_match "" abc123;              check "sha_match empty expected → 1" 1 "$?"
sha_match abc123 "";             check "sha_match empty actual → 1" 1 "$?"

# ---------------------------------------------------------------------------
# 5. poll_blocker — green vs stall surfaces the blocking sub-check
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  ALL_GREEN='{"check_runs":[{"name":"Otta Gate","status":"completed","conclusion":"success"},{"name":"ciGreen","status":"completed","conclusion":"success"}]}'
  out="$(poll_blocker "$ALL_GREEN")"; rc=$?
  check "poll_blocker all green → green" "green" "$out"
  check "poll_blocker all green → exit 0" 0 "$rc"

  # CI check queued with no runner → must surface the stuck sub-check, not hang.
  NO_RUNNER='{"check_runs":[{"name":"Otta Gate","status":"completed","conclusion":"success"},{"name":"ciGreen","status":"queued","conclusion":null}]}'
  out="$(poll_blocker "$NO_RUNNER")"; rc=$?
  case "$out" in
    *ciGreen*) check "poll_blocker no-runner names the blocking check" "yes" "yes" ;;
    *)         check "poll_blocker no-runner names the blocking check" "yes" "no ($out)" ;;
  esac
  case "$out" in
    *runner*|*stuck*) check "poll_blocker no-runner explains the stall" "yes" "yes" ;;
    *)                check "poll_blocker no-runner explains the stall" "yes" "no ($out)" ;;
  esac
  check "poll_blocker not-green → exit 1" 1 "$rc"

  # A failing sub-check surfaces its name + conclusion.
  FAILED='{"check_runs":[{"name":"test","status":"completed","conclusion":"failure"}]}'
  out="$(poll_blocker "$FAILED")"; rc=$?
  case "$out" in *test*failure*) check "poll_blocker failure names check+reason" "yes" "yes" ;; *) check "poll_blocker failure names check+reason" "yes" "no ($out)" ;; esac
  check "poll_blocker failure → exit 1" 1 "$rc"
else
  echo "  ⚠ python3 not available — skipping poll_blocker checks"
fi

# ---------------------------------------------------------------------------
# 6. verify_deploy — generic 'none' path + coolify requires env
# ---------------------------------------------------------------------------
out="$(verify_deploy none abc123 sha-match)"; rc=$?
check "verify_deploy none → exit 0" 0 "$rc"
case "$out" in *generic*) check "verify_deploy none → generic message" "yes" "yes" ;; *) check "verify_deploy none → generic message" "yes" "no" ;; esac

# coolify with no env → clean refusal (exit 2), no crash, no hardcoded creds.
( unset OTTA_COOLIFY_URL OTTA_COOLIFY_TOKEN OTTA_COOLIFY_APP_UUID; verify_deploy coolify abc123 sha-match >/dev/null 2>&1 ); check "verify_deploy coolify no-env → exit 2 (needs env)" 2 "$?"

# ---------------------------------------------------------------------------
# 7. AC2: _run() guard — fails when git remote origin is missing/empty
# ---------------------------------------------------------------------------
# Override git as a function (inherited by subshells) to simulate no remote.
git() { :; }
_ac2_out="$(_run 123 2>&1)"; _ac2_rc=$?
unset -f git
check "AC2 _run no-origin → exit 1" 1 "$_ac2_rc"
case "$_ac2_out" in
  *"cannot determine repo"*) check "AC2 _run no-origin → error message" "yes" "yes" ;;
  *) check "AC2 _run no-origin → error message" "yes" "no ($_ac2_out)" ;;
esac

# ---------------------------------------------------------------------------
# 8. AC3: verify_deploy coolify — polling loop retries before timing out
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  # curl stub always returns a non-matching SHA so the loop must retry.
  # sleep stub is instant so the test runs fast.
  export OTTA_COOLIFY_URL="http://fake" OTTA_COOLIFY_TOKEN="tok" OTTA_COOLIFY_APP_UUID="app"
  export OTTA_SHA_POLL_TIMEOUT=10
  curl() { printf '{"commit":"deadbeef"}'; }
  sleep() { :; }
  _ac3_out="$(verify_deploy coolify abc123abc sha-match 2>&1)"; _ac3_rc=$?
  unset -f curl sleep
  unset OTTA_COOLIFY_URL OTTA_COOLIFY_TOKEN OTTA_COOLIFY_APP_UUID OTTA_SHA_POLL_TIMEOUT
  case "$_ac3_out" in
    *"waiting for Coolify"*) check "AC3 coolify loop emits waiting message" "yes" "yes" ;;
    *) check "AC3 coolify loop emits waiting message" "yes" "no ($_ac3_out)" ;;
  esac
  check "AC3 coolify loop → exit 1 after timeout" 1 "$_ac3_rc"
fi

echo "  → $pass passed, $fail failed"
[ "$fail" -eq 0 ]
