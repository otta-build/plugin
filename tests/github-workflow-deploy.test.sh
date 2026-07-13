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

echo "  → $pass passed, $fail failed"
[ "$fail" -eq 0 ]
