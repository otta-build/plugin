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

Y="$(mk_yml workflow 'deploy:
  auto: human-approve
  target: production
  executor: github-workflow
  workflow: deploy-production.yml
  ref: release
  sha_input: expected_sha
  provider: coolify
  verify: health-sha
  health_url: https://example.test/health
  health_commit_field: revision')"
check "parse executor=github-workflow" "github-workflow" "$(parse_deploy_executor "$Y")"
check "parse workflow" "deploy-production.yml" "$(parse_deploy_workflow "$Y")"
check "parse workflow ref" "release" "$(parse_deploy_ref "$Y")"
check "parse SHA input" "expected_sha" "$(parse_deploy_sha_input "$Y")"
check "parse health URL" "https://example.test/health" "$(parse_deploy_health_url "$Y")"
check "parse health commit field" "revision" "$(parse_deploy_health_commit_field "$Y")"

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
check "absent → executor defaults none"     "none"           "$(parse_deploy_executor "$Y")"
check "absent → workflow ref defaults main" "main"           "$(parse_deploy_ref "$Y")"
check "absent → SHA input defaults commit_sha" "commit_sha"   "$(parse_deploy_sha_input "$Y")"
check "absent → health field defaults commit" "commit"       "$(parse_deploy_health_commit_field "$Y")"
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

# GitHub-workflow delivery separates immutable approval from execution (#137 AC2).
check "workflow human approval absent → wait-human" "wait-human" \
  "$(decide_delivery_action human-approve OPEN github-workflow '' abc123 true)"
check "workflow approved open PR → merge-dispatch" "merge-dispatch" \
  "$(decide_delivery_action human-approve OPEN github-workflow abc123 abc123 true)"
check "workflow changed head invalidates approval" "invalid-approval" \
  "$(decide_delivery_action human-approve OPEN github-workflow abc123 def456 true)"
check "workflow approval never accepts a SHA prefix" "invalid-approval" \
  "$(decide_delivery_action human-approve OPEN github-workflow a abc123 true)"
check "workflow approved merged PR → dispatch only" "dispatch" \
  "$(decide_delivery_action human-approve MERGED github-workflow abc123 abc123 true)"
check "workflow merged PR without approval → wait-human" "wait-human" \
  "$(decide_delivery_action human-approve MERGED github-workflow '' abc123 true)"
check "workflow merge-on-green remains merge-only" "merge-only" \
  "$(decide_delivery_action merge-on-green OPEN github-workflow '' abc123 true)"
check "workflow merge-and-deploy merges and dispatches" "merge-dispatch" \
  "$(decide_delivery_action merge-and-deploy OPEN github-workflow '' abc123 true)"
check "executor none uses legacy policy" "legacy" \
  "$(decide_delivery_action human-approve OPEN none '' abc123 true)"

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

# Workflow executor refuses mutation without a matching immutable approval.
Y="$(mk_yml approval 'deploy:
  auto: human-approve
  target: production
  executor: github-workflow
  workflow: deploy-production.yml
  ref: main
  sha_input: commit_sha
  provider: coolify
  verify: health-sha
  health_url: https://example.test/health
  health_commit_field: commit')"
CALLS="$TMP/approval-calls"
git() { [ "$1" = remote ] && echo "https://github.com/acme/widgets.git" || :; }
gh() {
  printf '%s\n' "$*" >> "$CALLS"
  if [ "$1 $2" = "pr view" ]; then
    printf '{"url":"https://github.com/acme/widgets/pull/42","state":"OPEN","headRefOid":"abc123","baseRefName":"main","baseRefOid":"base1","mergeCommit":null}\n'
  fi
}
_approval_out="$(_run 42 --otta-yml "$Y" 2>&1)"; _approval_rc=$?
check "workflow no approval stops safely" 1 "$_approval_rc"
case "$_approval_out" in *"approval"*"abc123"*) check "workflow no approval shows exact head" yes yes ;; *) check "workflow no approval shows exact head" yes "no ($_approval_out)" ;; esac
if grep -Eq 'pr merge|workflow run' "$CALLS"; then
  check "workflow no approval performs no mutation" yes no
else
  check "workflow no approval performs no mutation" yes yes
fi

: > "$CALLS"
_changed_out="$(_run 42 --otta-yml "$Y" --approved-head deadbeef 2>&1)"; _changed_rc=$?
check "changed PR head invalidates approval" 1 "$_changed_rc"
case "$_changed_out" in *"invalid"*"deadbeef"*"abc123"*) check "invalid approval reports both SHAs" yes yes ;; *) check "invalid approval reports both SHAs" yes "no ($_changed_out)" ;; esac
if grep -Eq 'pr merge|workflow run' "$CALLS"; then
  check "changed approval performs no mutation" yes no
else
  check "changed approval performs no mutation" yes yes
fi

: > "$CALLS"
_prefix_out="$(_run 42 --otta-yml "$Y" --approved-head a 2>&1)"; _prefix_rc=$?
check "prefix approval is rejected at initial boundary" 1 "$_prefix_rc"
if grep -Eq 'pr merge|workflow run' "$CALLS"; then
  check "prefix approval performs no mutation" yes no
else
  check "prefix approval performs no mutation" yes yes
fi
unset -f git gh

# End-to-end orchestration routes only the configured workflow executor through
# the adapter, and an already-merged PR is never merged again.
ORCH_CALLS="$TMP/orch-calls"
export OTTA_DEPLOY_POLL_TIMEOUT=0 OTTA_DEPLOY_POLL_INTERVAL=1
git() { [ "$1" = remote ] && echo "https://github.com/acme/widgets.git" || :; }
run_github_workflow_deploy() {
  printf 'adapter retry=%s resolve=%s args=%s\n' \
    "${OTTA_DEPLOY_RETRY_FAILED_RUN:-}" "${OTTA_DEPLOY_RESOLVE_RUN_ID:-}" "$*" >> "$ORCH_CALLS"
  return "${ADAPTER_RC:-0}"
}
gh() {
  printf 'gh %s\n' "$*" >> "$ORCH_CALLS"
  case "$1 $2" in
    "pr view")
      case "$*" in
        *"--json mergeCommit -q"*) printf 'merge123\n' ;;
        *) printf '{"url":"https://github.com/acme/widgets/pull/42","state":"OPEN","headRefOid":"abc123","baseRefName":"main","baseRefOid":"base1","mergeCommit":null}\n' ;;
      esac
      ;;
    "pr checks") printf '[{"name":"ci","state":"SUCCESS"}]\n' ;;
    "pr merge") return 0 ;;
  esac
}
: > "$ORCH_CALLS"
_orch_out="$(_run 42 --otta-yml "$Y" --approved-head abc123 2>&1)"; _orch_rc=$?
check "approved open PR workflow path succeeds" 0 "$_orch_rc"
check "approved open PR merges once" 1 "$(grep -c '^gh pr merge ' "$ORCH_CALLS")"
case "$(grep '^adapter ' "$ORCH_CALLS")" in *"merge123"*"https://example.test/health"*"commit"*) check "open PR dispatches adapter with merge SHA and health contract" yes yes ;; *) check "open PR dispatches adapter with merge SHA and health contract" yes no ;; esac

# A push while checks are polling invalidates approval even when the refreshed
# head only extends the approved text as a SHA prefix.
REFRESH_COUNT="$TMP/refresh-count"; printf '0\n' > "$REFRESH_COUNT"
gh() {
  printf 'gh %s\n' "$*" >> "$ORCH_CALLS"
  case "$1 $2" in
    "pr view")
      count="$(cat "$REFRESH_COUNT")"; count=$((count + 1)); printf '%s\n' "$count" > "$REFRESH_COUNT"
      if [ "$count" -eq 1 ]; then
        printf '{"url":"https://github.com/acme/widgets/pull/42","state":"OPEN","headRefOid":"abc123","baseRefName":"main","baseRefOid":"base1","mergeCommit":null}\n'
      else
        printf '{"url":"https://github.com/acme/widgets/pull/42","state":"OPEN","headRefOid":"abc1234","baseRefName":"main","baseRefOid":"base1","mergeCommit":null}\n'
      fi
      ;;
    "pr checks") printf '[{"name":"ci","state":"SUCCESS"}]\n' ;;
    "pr merge") return 0 ;;
  esac
}
: > "$ORCH_CALLS"
_refresh_out="$(_run 42 --otta-yml "$Y" --approved-head abc123 2>&1)"; _refresh_rc=$?
check "prefix drift is rejected at refreshed boundary" 1 "$_refresh_rc"
check "refreshed prefix drift performs no merge" 0 "$(grep -c '^gh pr merge ' "$ORCH_CALLS" || true)"

gh() {
  printf 'gh %s\n' "$*" >> "$ORCH_CALLS"
  [ "$1 $2" = "pr view" ] && {
    printf '{"url":"https://github.com/acme/widgets/pull/42","state":"MERGED","headRefOid":"abc123","baseRefName":"main","baseRefOid":"base1","mergeCommit":{"oid":"merged999"}}\n'; return 0
  }
  return 1
}
: > "$ORCH_CALLS"
_merged_out="$(_run 42 --otta-yml "$Y" --approved-head abc123 2>&1)"; _merged_rc=$?
check "approved merged PR dispatch path succeeds" 0 "$_merged_rc"
check "approved merged PR is not merged again" 0 "$(grep -c '^gh pr merge ' "$ORCH_CALLS" || true)"
case "$(grep '^adapter ' "$ORCH_CALLS")" in *"merged999"*) check "merged PR dispatches its recorded merge SHA" yes yes ;; *) check "merged PR dispatches its recorded merge SHA" yes no ;; esac

: > "$ORCH_CALLS"
_recovery_out="$(_run 42 --otta-yml "$Y" --approved-head abc123 --retry-failed-run --resolve-run-id 55 2>&1)"; _recovery_rc=$?
check "explicit recovery flags reach the adapter" 0 "$_recovery_rc"
case "$(grep '^adapter ' "$ORCH_CALLS")" in *"retry=true"*"resolve=55"*) check "recovery flags are scoped to workflow execution" yes yes ;; *) check "recovery flags are scoped to workflow execution" yes no ;; esac

ADAPTER_RC=1
: > "$ORCH_CALLS"
_failed_out="$(_run 42 --otta-yml "$Y" --approved-head abc123 2>&1)"; _failed_rc=$?
check "adapter workflow or health failure propagates" 1 "$_failed_rc"
unset ADAPTER_RC

MISSING="$(mk_yml missingworkflow 'deploy:
  auto: human-approve
  target: production
  executor: github-workflow
  health_url: https://example.test/health')"
: > "$ORCH_CALLS"
_missing_out="$(_run 42 --otta-yml "$MISSING" --approved-head abc123 2>&1)"; _missing_rc=$?
check "missing configured workflow fails before mutation" 1 "$_missing_rc"
check "missing workflow performs no merge or dispatch" 0 "$(grep -Ec '^gh pr merge |^adapter ' "$ORCH_CALLS" || true)"

unset -f git gh run_github_workflow_deploy
unset OTTA_DEPLOY_POLL_TIMEOUT OTTA_DEPLOY_POLL_INTERVAL

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

# ---------------------------------------------------------------------------
# 9. AC2 (issue #88): poll-loop status lines throttled to <=1 per 60s of wait,
#    not once per tick — otherwise a 600s/10s poll spams 60 lines.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  # sha-poll loop: interval=10s, timeout=130s → 13 ticks; throttled to 60s
  # apart should emit far fewer than 13 "waiting" lines.
  export OTTA_COOLIFY_URL="http://fake" OTTA_COOLIFY_TOKEN="tok" OTTA_COOLIFY_APP_UUID="app"
  export OTTA_SHA_POLL_TIMEOUT=130
  curl() { printf '{"commit":"deadbeef"}'; }
  sleep() { :; }
  _ac9_out="$(verify_deploy coolify abc123abc sha-match 2>&1)"
  unset -f curl sleep
  unset OTTA_COOLIFY_URL OTTA_COOLIFY_TOKEN OTTA_COOLIFY_APP_UUID OTTA_SHA_POLL_TIMEOUT
  _ac9_lines="$(printf '%s\n' "$_ac9_out" | grep -c 'waiting for Coolify')"
  check "AC2 sha-poll throttled (<=3 lines over 130s/10s ticks, not 13)" "yes" "$([ "$_ac9_lines" -le 3 ] && echo yes || echo "no ($_ac9_lines)")"

  # gate-poll loop inside _run: interval=10s, timeout=130s, gate never green.
  git() { [ "$1" = "remote" ] && echo "https://github.com/acme/widgets.git" || :; }
  gh() { echo '[{"name":"ciGreen","state":"QUEUED"}]'; }
  export -f git gh
  export OTTA_DEPLOY_POLL_TIMEOUT=130 OTTA_DEPLOY_POLL_INTERVAL=10
  Y="$(mk_yml gatepoll 'deploy:
  auto: merge-on-green
  target: staging
  provider: none')"
  sleep() { :; }
  _ac9b_out="$(_run 99 --otta-yml "$Y" 2>&1)"
  unset -f sleep git gh
  unset OTTA_DEPLOY_POLL_TIMEOUT OTTA_DEPLOY_POLL_INTERVAL
  _ac9b_lines="$(printf '%s\n' "$_ac9b_out" | grep -c 'waiting for gate')"
  check "AC2 gate-poll throttled (<=3 lines over 130s/10s ticks, not 13)" "yes" "$([ "$_ac9b_lines" -le 3 ] && echo yes || echo "no ($_ac9b_lines)")"
fi

# ---------------------------------------------------------------------------
# 10. AC (issue #100): self_audit — green-but-skipped detection (AC2)
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  # All success → self_audit returns 0, no incident written.
  ALL_SUCCESS='{"check_runs":[{"name":"Otta Gate","status":"completed","conclusion":"success"},{"name":"ci","status":"completed","conclusion":"success"}]}'
  AUDIT_LEDGER="$TMP/audit-ledger"
  mkdir -p "$AUDIT_LEDGER"
  OTTA_LEDGER_DIR="$AUDIT_LEDGER" self_audit "$ALL_SUCCESS" "acme/widget" "42"; _sa_rc=$?
  check "AC(#100) all-success → self_audit returns 0" 0 "$_sa_rc"
  # No incident written for all-success.
  check "AC(#100) all-success → no incident file" "no" "$([ -f "$AUDIT_LEDGER/acme-widget.jsonl" ] && echo yes || echo no)"

  # Skipped check → self_audit returns non-zero + incident written.
  SKIPPED='{"check_runs":[{"name":"Otta Gate","status":"completed","conclusion":"success"},{"name":"ci","status":"completed","conclusion":"skipped"}]}'
  OTTA_LEDGER_DIR="$AUDIT_LEDGER" self_audit "$SKIPPED" "acme/widget" "42" 2>/dev/null; _sa_skipped_rc=$?
  check "AC(#100) skipped check → self_audit returns non-zero" 1 "$_sa_skipped_rc"

  # AC3: incident jsonl written with source:deploy_audit.
  INCIDENT_FILE="$AUDIT_LEDGER/acme-widget.jsonl"
  [ -f "$INCIDENT_FILE" ] || { check "AC(#100) incident file created" yes "no (file absent)"; }
  if [ -f "$INCIDENT_FILE" ]; then
    case "$(cat "$INCIDENT_FILE")" in
      *'"source":"deploy_audit"'*) check "AC(#100) incident has source:deploy_audit" yes yes ;;
      *) check "AC(#100) incident has source:deploy_audit" yes "no ($(cat "$INCIDENT_FILE"))" ;;
    esac
    case "$(cat "$INCIDENT_FILE")" in
      *'"finding":"green-but-skipped"'*) check "AC(#100) incident has finding:green-but-skipped" yes yes ;;
      *) check "AC(#100) incident has finding:green-but-skipped" yes "no ($(cat "$INCIDENT_FILE"))" ;;
    esac
    case "$(cat "$INCIDENT_FILE")" in
      *'"repo":"acme/widget"'*) check "AC(#100) incident has repo field" yes yes ;;
      *) check "AC(#100) incident has repo field" yes "no ($(cat "$INCIDENT_FILE"))" ;;
    esac
  fi

  # Neutral conclusion also treated as NOT passing.
  NEUTRAL_LEDGER="$TMP/neutral-ledger"; mkdir -p "$NEUTRAL_LEDGER"
  NEUTRAL='{"check_runs":[{"name":"Otta Gate","status":"completed","conclusion":"success"},{"name":"optional-check","status":"completed","conclusion":"neutral"}]}'
  OTTA_LEDGER_DIR="$NEUTRAL_LEDGER" self_audit "$NEUTRAL" "acme/widget" "43" 2>/dev/null; _sa_neutral_rc=$?
  check "AC(#100) neutral check → self_audit returns non-zero" 1 "$_sa_neutral_rc"

  # Logging: self_audit emits one status line per question (4 questions = 4 lines).
  LOGGING_LEDGER="$TMP/log-ledger"; mkdir -p "$LOGGING_LEDGER"
  _audit_log="$(OTTA_LEDGER_DIR="$LOGGING_LEDGER" self_audit "$ALL_SUCCESS" "acme/widget" "0" 2>&1)"
  _audit_lines="$(printf '%s\n' "$_audit_log" | grep -c "deploy-audit:" || true)"
  check "AC(#100) self_audit logs at least 4 status lines (one per question)" "yes" \
    "$([ "$_audit_lines" -ge 4 ] && echo yes || echo "no ($_audit_lines lines)")"
fi

# Legacy merge-and-deploy keeps its provider verification route when no new
# executor is configured (#137 AC6).
LEGACY_ORCH="$(mk_yml legacyorch 'deploy:
  auto: merge-and-deploy
  target: staging
  provider: none
  verify: sha-match')"
LEGACY_CALLS="$TMP/legacy-orch-calls"; : > "$LEGACY_CALLS"
git() { [ "$1" = remote ] && echo "https://github.com/acme/widgets.git" || :; }
gh() {
  printf '%s\n' "$*" >> "$LEGACY_CALLS"
  case "$1 $2" in
    "pr checks") printf '[{"name":"ci","state":"SUCCESS"}]\n' ;;
    "pr merge") return 0 ;;
    "pr view")
      case "$*" in
        *"--json mergeCommit -q"*) printf 'legacy123\n' ;;
        *) printf '{"url":"https://github.com/acme/widgets/pull/77","state":"OPEN","headRefOid":"abc123","baseRefName":"main","baseRefOid":"base123","mergeCommit":null}\n' ;;
      esac
      ;;
  esac
}
# shellcheck disable=SC1007  # `VAR= cmd` is an intentional empty-value env prefix for one command — setting the variable empty is exactly what this case tests
legacy_out="$(OTTA_PULSE_URL= OTTA_PULSE_TOKEN= _run 77 --otta-yml "$LEGACY_ORCH" 2>&1)"; legacy_rc=$?
check "legacy merge-and-deploy still succeeds" 0 "$legacy_rc"
check "legacy merge-and-deploy still merges" 1 "$(grep -c '^pr merge ' "$LEGACY_CALLS")"
case "$legacy_out" in *"provider 'none'"*) check "legacy route still invokes provider verification" yes yes ;; *) check "legacy route still invokes provider verification" yes no ;; esac
unset -f git gh

# ---------------------------------------------------------------------------
# 11. Issue #153 — deploy PR state/merge resolution scoped by repository.
# AC1/AC2: canonical repo is re-derived from git remote origin on every
# invocation and threaded through every gh call — no cross-invocation state to
# go stale. AC3: one live `gh pr view` read prints repo/URL/head/base before
# any merge. AC5: fails closed when the PR's own URL doesn't resolve back to
# the canonical repo, or the PR isn't OPEN, instead of trusting `gh pr
# merge`'s silent no-op on an already-merged/foreign PR (the exact false
# "deploy: merged PR #17" the issue reported).
# ---------------------------------------------------------------------------

# 11a. Pure helper: extracts owner/repo from a PR URL.
check "AC1 _pr_url_repo extracts owner/repo" "acme/widgets" "$(_pr_url_repo "https://github.com/acme/widgets/pull/42")"
check "AC1 _pr_url_repo on garbage → empty" "" "$(_pr_url_repo "not-a-url")"

# 11b. Pure helper: identity check passes when URL repo matches canonical repo.
MATCH_JSON='{"url":"https://github.com/acme/widgets/pull/42","state":"OPEN","headRefOid":"headsha1","baseRefName":"main","baseRefOid":"basesha1"}'
_match_out="$(_print_and_verify_pr_identity "acme/widgets" 42 "$MATCH_JSON")"; _match_rc=$?
check "AC3 identity match → exit 0" 0 "$_match_rc"
case "$_match_out" in
  *"acme/widgets"*"headsha1"*"basesha1"*) check "AC3 identity match prints repo/head/base" yes yes ;;
  *) check "AC3 identity match prints repo/head/base" yes "no ($_match_out)" ;;
esac

# 11c. AC5: identity check fails closed when the live URL resolves to a
# different repository than the canonical one we intended to query.
MISMATCH_JSON='{"url":"https://github.com/GitPWeb/billing-new/pull/17","state":"MERGED","headRefOid":"upstream1","baseRefName":"main","baseRefOid":"basesha2"}'
_mismatch_out="$(_print_and_verify_pr_identity "wiselancer/billing-new" 17 "$MISMATCH_JSON" 2>&1)"; _mismatch_rc=$?
check "AC5 identity mismatch → exit 1" 1 "$_mismatch_rc"
case "$_mismatch_out" in
  *"GitPWeb/billing-new"*"wiselancer/billing-new"*) check "AC5 mismatch names both repos" yes yes ;;
  *) check "AC5 mismatch names both repos" yes "no ($_mismatch_out)" ;;
esac

# 11d. AC4 end-to-end: two repositories, PR #17 in different states, run back
# to back. The stale/foreign "already merged" resolution from repo A must
# never leak into repo B's fresh, still-open PR #17.
AC4_A="$TMP/ac4-repo-a-calls"; AC4_B="$TMP/ac4-repo-b-calls"

REPOA_ORCH="$(mk_yml repoa 'deploy:
  auto: merge-on-green
  target: staging
  provider: none')"
git() { [ "$1" = remote ] && echo "https://github.com/GitPWeb/billing-new.git" || :; }
gh() {
  printf '%s\n' "$*" >> "$AC4_A"
  case "$1 $2" in
    "pr checks") printf '[{"name":"ci","state":"SUCCESS"}]\n' ;;
    "pr view") printf '{"url":"https://github.com/GitPWeb/billing-new/pull/17","state":"MERGED","headRefOid":"upstream1","baseRefName":"main","baseRefOid":"base1","mergeCommit":{"oid":"upstreammerge1"}}\n' ;;
    "pr merge") echo "! Pull request GitPWeb/billing-new#17 was already merged" >&2; return 0 ;;
  esac
}
_repoa_out="$(_run 17 --otta-yml "$REPOA_ORCH" 2>&1)"; _repoa_rc=$?
check "AC4 repo A (already-merged PR #17) fails closed, no false merge report" 1 "$_repoa_rc"
case "$_repoa_out" in *"deploy: merged PR #17"*) check "AC4 repo A does not report a false merge" yes no ;; *) check "AC4 repo A does not report a false merge" yes yes ;; esac
check "AC4 repo A never calls pr merge on an already-merged PR" 0 "$(grep -c '^pr merge ' "$AC4_A" || true)"
unset -f git gh

REPOB_ORCH="$(mk_yml repob 'deploy:
  auto: merge-on-green
  target: staging
  provider: none')"
git() { [ "$1" = remote ] && echo "https://github.com/wiselancer/billing-new.git" || :; }
gh() {
  printf '%s\n' "$*" >> "$AC4_B"
  case "$1 $2" in
    "pr checks") printf '[{"name":"ci","state":"SUCCESS"}]\n' ;;
    "pr view")
      case "$*" in
        *"--json mergeCommit -q"*) printf 'forkmerge1\n' ;;
        *) printf '{"url":"https://github.com/wiselancer/billing-new/pull/17","state":"OPEN","headRefOid":"forkhead1","baseRefName":"main","baseRefOid":"base2","mergeCommit":null}\n' ;;
      esac
      ;;
    "pr merge") return 0 ;;
  esac
}
_repob_out="$(_run 17 --otta-yml "$REPOB_ORCH" 2>&1)"; _repob_rc=$?
check "AC4 repo B (fresh open fork PR #17) merges its own PR" 0 "$_repob_rc"
case "$_repob_out" in *"deploy: merged PR #17 at forkmerge1"*) check "AC4 repo B reports its own real merge SHA" yes yes ;; *) check "AC4 repo B reports its own real merge SHA" yes "no ($_repob_out)" ;; esac
check "AC4 repo B calls pr merge exactly once on its own open PR" 1 "$(grep -c '^pr merge ' "$AC4_B" || true)"
case "$_repob_out" in *"upstream1"*|*"GitPWeb"*) check "AC2 repo B output carries no repo-A residue" yes no ;; *) check "AC2 repo B output carries no repo-A residue" yes yes ;; esac
unset -f git gh

# 11e. github-workflow executor pre-merge refresh: the PR can merge (by any
# actor) between the initial read (:444) and the refresh right before mutation
# (:526). auto=merge-on-green/merge-and-deploy must not trust `gh pr merge`'s
# own exit code on that race — it must see state=MERGED at the refresh and
# fail closed, same as the legacy path already does.
RACE_CALLS="$TMP/race-calls"; : > "$RACE_CALLS"
RACE_Y="$(mk_yml race 'deploy:
  auto: merge-on-green
  target: staging
  executor: github-workflow
  workflow: deploy-staging.yml
  ref: main
  sha_input: commit_sha
  provider: none
  verify: none
  health_url: https://example.test/health
  health_commit_field: commit')"
export OTTA_DEPLOY_POLL_TIMEOUT=0 OTTA_DEPLOY_POLL_INTERVAL=1
git() { [ "$1" = remote ] && echo "https://github.com/acme/widgets.git" || :; }
run_github_workflow_deploy() { printf 'adapter called\n' >> "$RACE_CALLS"; return 0; }
RACE_VIEW_COUNT="$TMP/race-view-count"; printf '0\n' > "$RACE_VIEW_COUNT"
gh() {
  printf '%s\n' "$*" >> "$RACE_CALLS"
  case "$1 $2" in
    "pr view")
      count="$(cat "$RACE_VIEW_COUNT")"; count=$((count + 1)); printf '%s\n' "$count" > "$RACE_VIEW_COUNT"
      if [ "$count" -eq 1 ]; then
        printf '{"url":"https://github.com/acme/widgets/pull/91","state":"OPEN","headRefOid":"racehead1","baseRefName":"main","baseRefOid":"base1","mergeCommit":null}\n'
      else
        printf '{"url":"https://github.com/acme/widgets/pull/91","state":"MERGED","headRefOid":"racehead1","baseRefName":"main","baseRefOid":"base1","mergeCommit":{"oid":"racemerge1"}}\n'
      fi
      ;;
    "pr checks") printf '[{"name":"ci","state":"SUCCESS"}]\n' ;;
    "pr merge") printf '! Pull request acme/widgets#91 was already merged\n' >&2; return 0 ;;
  esac
}
_race_out="$(_run 91 --otta-yml "$RACE_Y" 2>&1)"; _race_rc=$?
check "AC(#153) refresh-path race: already-merged at refresh → fails closed" 1 "$_race_rc"
check "AC(#153) refresh-path race: no second pr merge attempted" 0 "$(grep -c '^pr merge ' "$RACE_CALLS" || true)"
check "AC(#153) refresh-path race: adapter never dispatched" 0 "$(grep -c '^adapter called' "$RACE_CALLS" || true)"
case "$_race_out" in *"not OPEN"*"MERGED"*) check "AC(#153) refresh-path race: error names the state" yes yes ;; *) check "AC(#153) refresh-path race: error names the state" yes "no ($_race_out)" ;; esac
unset -f git gh run_github_workflow_deploy
unset OTTA_DEPLOY_POLL_TIMEOUT OTTA_DEPLOY_POLL_INTERVAL

# ---------------------------------------------------------------------------
# 12. AC(#205): provider 'none' + health_url — generic SHA verification.
# merge-and-deploy previously treated provider:none as identical to
# merge-on-green (no health_url wiring at all: declaring it in .otta.yml
# changed no behaviour). Now: verify:none stays an explicit no-op; a declared
# health_url + verify:sha-match|health-sha|health polls it for the merged SHA
# (JSON field per health_commit_field, falling back to a plain substring
# match for a page that just prints its SHA); no health_url reports clearly
# that verification is impossible rather than implying success; a persistent
# mismatch/timeout names both the expected and actual SHA and fails closed.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  # 12a. verify:none is an explicit no-op even when a health_url IS declared —
  # curl must never be called.
  CURL_CALLS="$TMP/curl-calls-205"; : > "$CURL_CALLS"
  curl() { echo "curl $*" >> "$CURL_CALLS"; printf '{"commit":"abc123"}'; }
  _205_noop_out="$(verify_deploy none abc123 none https://example.test/health commit 2>&1)"; _205_noop_rc=$?
  unset -f curl
  check "AC205 verify:none stays a no-op → exit 0" 0 "$_205_noop_rc"
  check "AC205 verify:none makes no health_url request" 0 "$(wc -l < "$CURL_CALLS" | tr -d ' ')"
  case "$_205_noop_out" in
    *"skipped"*|*"no-op"*) check "AC205 verify:none message says skipped" yes yes ;;
    *) check "AC205 verify:none message says skipped" yes "no ($_205_noop_out)" ;;
  esac

  # 12b. verify:sha-match with no health_url configured at all → reports
  # clearly that verification is impossible instead of implying success.
  _205_nourl_out="$(verify_deploy none abc123 sha-match 2>&1)"; _205_nourl_rc=$?
  check "AC205 no health_url → exit 0 (cannot fail what cannot be checked)" 0 "$_205_nourl_rc"
  case "$_205_nourl_out" in
    *"NOT verified"*|*"not verified"*) check "AC205 no health_url → says not verified" yes yes ;;
    *) check "AC205 no health_url → says not verified" yes "no ($_205_nourl_out)" ;;
  esac

  # 12c. Matching JSON commit field → verified, exit 0.
  curl() { printf '{"commit":"deadbeef123"}'; }
  _205_match_out="$(verify_deploy none deadbeef123 sha-match https://example.test/health commit 2>&1)"; _205_match_rc=$?
  unset -f curl
  check "AC205 health_url JSON commit match → exit 0" 0 "$_205_match_rc"
  case "$_205_match_out" in
    *"ok"*) check "AC205 health_url JSON commit match → ok message" yes yes ;;
    *) check "AC205 health_url JSON commit match → ok message" yes "no ($_205_match_out)" ;;
  esac

  # 12d. Custom health_commit_field is honoured (pulse-style config).
  curl() { printf '{"revision":"cafef00d"}'; }
  _205_field_out="$(verify_deploy none cafef00d sha-match https://example.test/health revision 2>&1)"; _205_field_rc=$?
  unset -f curl
  check "AC205 custom health_commit_field honoured → exit 0" 0 "$_205_field_rc"

  # 12e. Plain-text body (no JSON) containing the SHA as a substring still
  # verifies — a page that just prints its build SHA works.
  curl() { printf 'build ok: commit=abc123def sha ok'; }
  _205_substr_out="$(verify_deploy none abc123def sha-match https://example.test/health commit 2>&1)"; _205_substr_rc=$?
  unset -f curl
  check "AC205 plain substring match → exit 0" 0 "$_205_substr_rc"

  # 12f. Persistent mismatch → non-zero, names both expected and actual SHA,
  # and does not hang (short timeout, stubbed sleep).
  export OTTA_SHA_POLL_TIMEOUT=10
  curl() { printf '{"commit":"oldsha000"}'; }
  sleep() { :; }
  _205_mismatch_out="$(verify_deploy none newsha111 sha-match https://example.test/health commit 2>&1)"; _205_mismatch_rc=$?
  unset -f curl sleep
  unset OTTA_SHA_POLL_TIMEOUT
  check "AC205 mismatch after timeout → exit 1" 1 "$_205_mismatch_rc"
  case "$_205_mismatch_out" in
    *"newsha111"*"oldsha000"*) check "AC205 mismatch names expected and actual" yes yes ;;
    *) check "AC205 mismatch names expected and actual" yes "no ($_205_mismatch_out)" ;;
  esac

  # 12g. verify:health-sha and verify:health (the tokens actually used in the
  # fleet — otta-build/landing and otta-build/pulse respectively) both trigger
  # the same generic health-SHA verification as sha-match.
  curl() { printf '{"commit":"feedface1"}'; }
  _205_healthsha_out="$(verify_deploy none feedface1 health-sha https://example.test/health commit 2>&1)"; _205_healthsha_rc=$?
  _205_health_out="$(verify_deploy none feedface1 health https://example.test/health commit 2>&1)"; _205_health_rc=$?
  unset -f curl
  check "AC205 verify:health-sha verifies like sha-match" 0 "$_205_healthsha_rc"
  check "AC205 verify:health verifies like sha-match" 0 "$_205_health_rc"

  # 12h. End-to-end through _run(): merge-and-deploy + provider none +
  # health_url actually gates on the health-SHA outcome instead of being
  # silently green regardless (the bug the issue reports).
  E2E_205="$(mk_yml e2e205 'deploy:
  auto: merge-and-deploy
  target: staging
  provider: none
  verify: sha-match
  health_url: https://example.test/health
  health_commit_field: commit')"
  git() { [ "$1" = remote ] && echo "https://github.com/acme/widgets.git" || :; }
  gh() {
    case "$1 $2" in
      "pr checks") printf '[{"name":"ci","state":"SUCCESS"}]\n' ;;
      "pr merge") return 0 ;;
      "pr view")
        case "$*" in
          *"--json mergeCommit -q"*) printf 'e2emerge205\n' ;;
          *) printf '{"url":"https://github.com/acme/widgets/pull/205","state":"OPEN","headRefOid":"head205","baseRefName":"main","baseRefOid":"base205","mergeCommit":null}\n' ;;
        esac
        ;;
    esac
  }
  curl() { printf '{"commit":"e2emerge205"}'; }
  _205_e2e_ok_out="$(_run 205 --otta-yml "$E2E_205" 2>&1)"; _205_e2e_ok_rc=$?
  check "AC205 e2e: matching health SHA → _run succeeds" 0 "$_205_e2e_ok_rc"

  curl() { printf '{"commit":"wrongsha"}'; }
  export OTTA_SHA_POLL_TIMEOUT=1
  sleep() { :; }
  _205_e2e_fail_out="$(_run 205 --otta-yml "$E2E_205" 2>&1)"; _205_e2e_fail_rc=$?
  unset -f sleep
  unset OTTA_SHA_POLL_TIMEOUT
  check "AC205 e2e: mismatching health SHA → _run fails, not silently green" 1 "$_205_e2e_fail_rc"
  unset -f git gh curl
fi

echo "  → $pass passed, $fail failed"
[ "$fail" -eq 0 ]
