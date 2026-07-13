#!/usr/bin/env bash
# Regression tests for the GitHub workflow deployment adapter (#137).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/github-workflow-deploy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ✓ $1"; pass=$((pass + 1))
  else
    echo "  ✗ $1 — expected [$2], got [$3]"; fail=$((fail + 1))
  fi
}

[ -f "$SCRIPT" ] || { echo "✗ script not found: $SCRIPT" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SCRIPT"

echo "github-workflow-deploy:"

key1="$(workflow_deploy_key acme/widget deploy.yml production abc123)"
key2="$(workflow_deploy_key acme/widget deploy.yml production abc123)"
key3="$(workflow_deploy_key acme/widget deploy.yml staging abc123)"
check "stable identity is deterministic" "$key1" "$key2"
check "environment participates in identity" yes "$([ "$key1" != "$key3" ] && echo yes || echo no)"

export OTTA_LEDGER_DIR="$TMP/ledger"
export OTTA_DISPATCH_RECONCILE_ATTEMPTS=1 OTTA_DISPATCH_RECONCILE_INTERVAL=0
CALLS="$TMP/calls"; : > "$CALLS"
LIST_COUNT="$TMP/list-count"; printf '0\n' > "$LIST_COUNT"
gh() {
  printf '%s\n' "$*" >> "$CALLS"
  if [ "$1 $2" = "run list" ]; then
    count="$(cat "$LIST_COUNT")"; count=$((count + 1)); printf '%s\n' "$count" > "$LIST_COUNT"
    if [ "$count" -eq 1 ]; then
      printf '[{"databaseId":10,"headSha":"abc123","createdAt":"2026-07-13T00:00:00Z"}]\n'
    else
      printf '[{"databaseId":10,"headSha":"abc123","createdAt":"2026-07-13T00:00:00Z"},{"databaseId":11,"headSha":"abc123","createdAt":"2026-07-13T00:00:01Z"}]\n'
    fi
    return 0
  fi
  [ "$1 $2" = "workflow run" ] && return 0
  return 1
}

run_id="$(ensure_workflow_dispatched acme/widget acme/widget production deploy.yml main sha abc123)"; rc=$?
check "first dispatch returns correlated run" 0 "$rc"
check "first dispatch correlates unseen run" 11 "$run_id"
check "first attempt dispatches exactly once" 1 "$(grep -c '^workflow run ' "$CALLS")"
check "correlation filters the immutable commit" yes "$(grep -q -- '--commit abc123' "$CALLS" && echo yes || echo no)"

run_id="$(ensure_workflow_dispatched acme/widget acme/widget production deploy.yml main sha abc123)"; rc=$?
check "retry reuses recorded run" 0 "$rc"
check "retry returns same run" 11 "$run_id"
check "retry does not redispatch" 1 "$(grep -c '^workflow run ' "$CALLS")"

# An uncertain dispatch reconciles, but zero matches remains unknown and never
# initiates a second ordinary deployment.
UNKNOWN_LEDGER="$TMP/unknown-ledger"; mkdir -p "$UNKNOWN_LEDGER"
export OTTA_LEDGER_DIR="$UNKNOWN_LEDGER"
unknown_key="$(workflow_deploy_key acme/unknown deploy.yml production def456)"
append_deploy_record acme/unknown deploy_dispatching "$unknown_key" \
  '{"workflow":"deploy.yml","ref":"main","sha":"def456","pre_run_ids":[]}' '{}' >/dev/null
: > "$CALLS"
gh() {
  printf '%s\n' "$*" >> "$CALLS"
  [ "$1 $2" = "run list" ] && { printf '[]\n'; return 0; }
  [ "$1 $2" = "workflow run" ] && return 0
  return 1
}
ensure_workflow_dispatched acme/unknown acme/unknown production deploy.yml main sha def456 >/dev/null 2>&1; rc=$?
check "uncertain zero-match stays unknown" 3 "$rc"
check "uncertain zero-match never redispatches" 0 "$(grep -c '^workflow run ' "$CALLS" || true)"
ensure_workflow_dispatched acme/unknown acme/unknown production deploy.yml main sha def456 >/dev/null 2>&1; rc=$?
check "unknown retry remains fail-closed" 3 "$rc"
check "unknown retry still never redispatches" 0 "$(grep -c '^workflow run ' "$CALLS" || true)"

# Multiple unseen candidates are ambiguous and must not be guessed.
AMBIG_LEDGER="$TMP/ambig-ledger"; mkdir -p "$AMBIG_LEDGER"
export OTTA_LEDGER_DIR="$AMBIG_LEDGER"
ambig_key="$(workflow_deploy_key acme/ambig deploy.yml production fedcba)"
append_deploy_record acme/ambig deploy_dispatching "$ambig_key" \
  '{"workflow":"deploy.yml","ref":"main","sha":"fedcba","pre_run_ids":[]}' '{}' >/dev/null
gh() {
  [ "$1 $2" = "run list" ] && {
    printf '[{"databaseId":21,"headSha":"fedcba"},{"databaseId":22,"headSha":"fedcba"}]\n'; return 0
  }
  return 1
}
ensure_workflow_dispatched acme/ambig acme/ambig production deploy.yml main sha fedcba >/dev/null 2>&1; rc=$?
check "multiple unseen runs fail ambiguous" 4 "$rc"

# A recorded terminal failure requires an explicit recovery action.
FAILED_LEDGER="$TMP/failed-ledger"; mkdir -p "$FAILED_LEDGER"
export OTTA_LEDGER_DIR="$FAILED_LEDGER"
failed_key="$(workflow_deploy_key acme/failed deploy.yml production bad123)"
append_deploy_record acme/failed deploy_workflow_failed "$failed_key" \
  '{"workflow":"deploy.yml","ref":"main","sha":"bad123"}' '{"run_id":31,"conclusion":"failure"}' >/dev/null
ensure_workflow_dispatched acme/failed acme/failed production deploy.yml main sha bad123 >/dev/null 2>&1; rc=$?
check "failed run refuses implicit retry" 5 "$rc"

RECOVERY_CALLS="$TMP/recovery-calls"; : > "$RECOVERY_CALLS"
gh() {
  printf '%s\n' "$*" >> "$RECOVERY_CALLS"
  [ "$1 $2" = "run rerun" ] && return 0
  return 1
}
OTTA_DEPLOY_RETRY_FAILED_RUN=true \
  ensure_workflow_dispatched acme/failed acme/failed production deploy.yml main sha bad123 >/dev/null 2>&1; rc=$?
check "explicit failed-run recovery is accepted" 0 "$rc"
check "explicit recovery reruns the recorded run only" 1 "$(grep -c '^run rerun 31 ' "$RECOVERY_CALLS")"
check "explicit rerun returns to dispatched state" deploy_dispatched \
  "$(deployment_last_record acme/failed "$failed_key" | jq -r .event)"

# An operator can resolve dispatch_unknown to an exact existing run, but the
# adapter validates its event and immutable head before attaching it.
export OTTA_LEDGER_DIR="$UNKNOWN_LEDGER"
gh() {
  [ "$1 $2" = "run view" ] && {
    printf '{"databaseId":55,"event":"workflow_dispatch","headSha":"def456","url":"https://example.test/runs/55"}\n'; return 0
  }
  return 1
}
OTTA_DEPLOY_RESOLVE_RUN_ID=55 \
  ensure_workflow_dispatched acme/unknown acme/unknown production deploy.yml main sha def456 >/dev/null 2>&1; rc=$?
check "explicit unknown-run resolution succeeds" 0 "$rc"
check "resolved run id is recorded" 55 \
  "$(deployment_last_record acme/unknown "$unknown_key" | jq -r .output.run_id)"

BAD_RESOLVE_LEDGER="$TMP/bad-resolve-ledger"; mkdir -p "$BAD_RESOLVE_LEDGER"
export OTTA_LEDGER_DIR="$BAD_RESOLVE_LEDGER"
bad_resolve_key="$(workflow_deploy_key acme/bad-resolve deploy.yml production exact1)"
append_deploy_record acme/bad-resolve deploy_dispatch_unknown "$bad_resolve_key" \
  '{"workflow":"deploy.yml","ref":"main","sha":"exact1","pre_run_ids":[]}' '{}' >/dev/null
gh() {
  [ "$1 $2" = "run view" ] && {
    printf '{"databaseId":56,"event":"workflow_dispatch","headSha":"wrong2","url":"https://example.test/runs/56"}\n'; return 0
  }
  return 1
}
OTTA_DEPLOY_RESOLVE_RUN_ID=56 \
  ensure_workflow_dispatched acme/bad-resolve acme/bad-resolve production deploy.yml main sha exact1 >/dev/null 2>&1; rc=$?
check "manual resolution rejects wrong run head" 6 "$rc"

# Workflow completion is necessary but not sufficient for a shipped verdict.
POLL_LEDGER="$TMP/poll-ledger"; mkdir -p "$POLL_LEDGER"
export OTTA_LEDGER_DIR="$POLL_LEDGER" OTTA_WORKFLOW_POLL_TIMEOUT=5 OTTA_WORKFLOW_POLL_INTERVAL=1
poll_key="$(workflow_deploy_key acme/poll deploy.yml production abc999)"
poll_input='{"workflow":"deploy.yml","ref":"main","sha":"abc999","pre_run_ids":[]}'
POLL_COUNT="$TMP/poll-count"; printf '0\n' > "$POLL_COUNT"
gh() {
  [ "$1 $2" = "run view" ] || return 1
  count="$(cat "$POLL_COUNT")"; count=$((count + 1)); printf '%s\n' "$count" > "$POLL_COUNT"
  case "$count" in
    1) printf '{"status":"queued","conclusion":null,"url":"https://example.test/runs/41","headSha":"abc999"}\n' ;;
    2) printf '{"status":"in_progress","conclusion":null,"url":"https://example.test/runs/41","headSha":"abc999"}\n' ;;
    *) printf '{"status":"completed","conclusion":"success","url":"https://example.test/runs/41","headSha":"abc999"}\n' ;;
  esac
}
sleep() { :; }
wait_for_workflow_terminal acme/poll acme/poll "$poll_key" "$poll_input" 41 abc999 >/dev/null 2>&1; rc=$?
check "queued to running to success reaches terminal success" 0 "$rc"
check "workflow success requires terminal poll" 3 "$(cat "$POLL_COUNT")"
check "workflow success is recorded" deploy_workflow_succeeded \
  "$(deployment_last_record acme/poll "$poll_key" | jq -r .event)"

FAIL_POLL_LEDGER="$TMP/fail-poll-ledger"; mkdir -p "$FAIL_POLL_LEDGER"
export OTTA_LEDGER_DIR="$FAIL_POLL_LEDGER"
fail_poll_key="$(workflow_deploy_key acme/fail-poll deploy.yml production bad999)"
gh() {
  [ "$1 $2" = "run view" ] && {
    printf '{"status":"completed","conclusion":"failure","url":"https://example.test/runs/42","headSha":"bad999"}\n'; return 0
  }
  return 1
}
wait_for_workflow_terminal acme/fail-poll acme/fail-poll "$fail_poll_key" \
  '{"workflow":"deploy.yml","sha":"bad999"}' 42 bad999 >/dev/null 2>&1; rc=$?
check "terminal workflow failure fails loudly" 1 "$rc"
check "terminal workflow failure is recorded" deploy_workflow_failed \
  "$(deployment_last_record acme/fail-poll "$fail_poll_key" | jq -r .event)"

CANCEL_LEDGER="$TMP/cancel-ledger"; mkdir -p "$CANCEL_LEDGER"
export OTTA_LEDGER_DIR="$CANCEL_LEDGER"
cancel_key="$(workflow_deploy_key acme/cancel deploy.yml production cancel9)"
gh() {
  [ "$1 $2" = "run view" ] && {
    printf '{"status":"completed","conclusion":"cancelled","url":"https://example.test/runs/44","headSha":"cancel9"}\n'; return 0
  }
  return 1
}
wait_for_workflow_terminal acme/cancel acme/cancel "$cancel_key" \
  '{"workflow":"deploy.yml","sha":"cancel9"}' 44 cancel9 >/dev/null 2>&1; rc=$?
check "cancelled workflow is terminal failure" 1 "$rc"
check "cancelled workflow conclusion is preserved" cancelled \
  "$(deployment_last_record acme/cancel "$cancel_key" | jq -r .output.conclusion)"

TIMEOUT_LEDGER="$TMP/timeout-ledger"; mkdir -p "$TIMEOUT_LEDGER"
export OTTA_LEDGER_DIR="$TIMEOUT_LEDGER" OTTA_WORKFLOW_POLL_TIMEOUT=1 OTTA_WORKFLOW_POLL_INTERVAL=1
timeout_key="$(workflow_deploy_key acme/timeout deploy.yml production wait999)"
append_deploy_record acme/timeout deploy_dispatched "$timeout_key" \
  '{"workflow":"deploy.yml","sha":"wait999"}' '{"run_id":43}' >/dev/null
gh() {
  [ "$1 $2" = "run view" ] && {
    printf '{"status":"in_progress","conclusion":null,"url":"https://example.test/runs/43","headSha":"wait999"}\n'; return 0
  }
  return 1
}
wait_for_workflow_terminal acme/timeout acme/timeout "$timeout_key" \
  '{"workflow":"deploy.yml","sha":"wait999"}' 43 wait999 >/dev/null 2>&1; rc=$?
check "workflow poll timeout fails" 1 "$rc"
check "workflow timeout preserves resumable dispatched run" deploy_dispatched \
  "$(deployment_last_record acme/timeout "$timeout_key" | jq -r .event)"

# Health verification retries boundedly, accepts SHA prefixes, and reports stale
# or unavailable state without ever accepting workflow success alone.
export OTTA_HEALTH_POLL_TIMEOUT=2 OTTA_HEALTH_POLL_INTERVAL=1
HEALTH_COUNT="$TMP/health-count"; printf '0\n' > "$HEALTH_COUNT"
curl() {
  count="$(cat "$HEALTH_COUNT")"; count=$((count + 1)); printf '%s\n' "$count" > "$HEALTH_COUNT"
  case "$count" in
    1) return 22 ;;
    2) printf '{"commit":"stale000"}\n' ;;
    *) printf '{"commit":"abcdef1"}\n' ;;
  esac
}
verify_health_sha https://example.test/health commit abcdef123456 >/dev/null 2>&1; rc=$?
check "health retries unavailable and stale responses" 0 "$rc"
check "health accepts eventual prefix-equivalent SHA" 3 "$(cat "$HEALTH_COUNT")"

export OTTA_HEALTH_POLL_TIMEOUT=0
curl() { printf '{"commit":"stale000"}\n'; }
health_error="$(verify_health_sha https://example.test/health commit abcdef123456 2>&1)"; rc=$?
check "stale live SHA fails" 1 "$rc"
case "$health_error" in *"expected abcdef123456"*"observed stale000"*) check "stale error reports exact SHAs" yes yes ;; *) check "stale error reports exact SHAs" yes "no ($health_error)" ;; esac

curl() { return 22; }
health_error="$(verify_health_sha https://example.test/health commit abcdef123456 2>&1)"; rc=$?
check "unreachable health endpoint fails" 1 "$rc"
case "$health_error" in *"unavailable"*"https://example.test/health"*) check "unreachable error reports URL and state" yes yes ;; *) check "unreachable error reports URL and state" yes "no ($health_error)" ;; esac

curl() { printf '{not-json}\n'; }
verify_health_sha https://example.test/health commit abcdef123456 >/dev/null 2>&1; rc=$?
check "malformed health JSON fails closed" 1 "$rc"
curl() { printf '{"status":"ok"}\n'; }
verify_health_sha https://example.test/health commit abcdef123456 >/dev/null 2>&1; rc=$?
check "missing health commit field fails closed" 1 "$rc"

unset -f gh sleep curl
unset OTTA_WORKFLOW_POLL_TIMEOUT OTTA_WORKFLOW_POLL_INTERVAL OTTA_HEALTH_POLL_TIMEOUT OTTA_HEALTH_POLL_INTERVAL

echo "  → $pass passed, $fail failed"
[ "$fail" -eq 0 ]
