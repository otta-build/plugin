#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/github-workflow-deploy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
check() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1: expected [$2], got [$3]"; failures=$((failures + 1)); fi
}
. "$SCRIPT"

echo 'github-workflow-latest-wins:'
check 'queued descendant supersedes' superseded "$(classify_release_successor a production b production true queued ahead)"
check 'running descendant supersedes' superseded "$(classify_release_successor a production b production true running ahead)"
check 'verified descendant includes' included "$(classify_release_successor a production b production true runtime_verified ahead)"
check 'same verified SHA includes' included "$(classify_release_successor a production a production true runtime_verified identical)"
check 'different environment blocks' blocked "$(classify_release_successor a staging b production true queued ahead)"
check 'unapproved candidate blocks' blocked "$(classify_release_successor a production b production false queued ahead)"
check 'divergent candidate blocks' blocked "$(classify_release_successor a production b production true queued diverged)"
check 'behind candidate blocks' blocked "$(classify_release_successor a production b production true queued behind)"
check 'unknown ancestry blocks' blocked "$(classify_release_successor a production b production true queued unknown)"
check 'cancelled candidate blocks' blocked "$(classify_release_successor a production b production true cancelled ahead)"
check 'rollback target blocks' blocked "$(classify_release_successor a production b production true rollback ahead)"

OLD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEW_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
RUN_STATE=queued
gh() {
  if [ "$1" = api ] && [[ "$2" == *'/runs?'* ]]; then
    printf '[{"databaseId":10,"status":"%s","conclusion":null,"displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:00Z","url":"https://example.test/runs/10"}]\n' "$RUN_STATE" "$NEW_SHA"
    return 0
  fi
  if [ "$1" = api ] && [[ "$2" == *'/compare/'* ]]; then printf 'ahead\n'; return 0; fi
  return 1
}
curl() { printf '{"commit":"%s"}\n' "$NEW_SHA"; }

pending="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; pending_rc=$?
check 'queued successor is non-terminal' 1 "$pending_rc"
check 'queued successor reports pending' successor_pending "$(printf '%s' "$pending" | jq -r .outcome)"

RUN_STATE=completed
gh() {
  if [ "$1" = api ] && [[ "$2" == *'/runs?'* ]]; then
    printf '[{"databaseId":10,"status":"completed","conclusion":"success","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:00Z","url":"https://example.test/runs/10"}]\n' "$NEW_SHA"
    return 0
  fi
  if [ "$1" = api ] && [[ "$2" == *'/compare/'* ]]; then printf 'ahead\n'; return 0; fi
  return 1
}
verified="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; verified_rc=$?
check 'verified descendant succeeds' 0 "$verified_rc"
check 'verified descendant is included' included "$(printf '%s' "$verified" | jq -r .outcome)"
check 'included proof carries descendant SHA' "$NEW_SHA" "$(printf '%s' "$verified" | jq -r .sha)"

gh() {
  if [ "$1" = api ] && [[ "$2" == *'/runs?'* ]]; then
    printf '[{"databaseId":11,"status":"completed","conclusion":"success","displayTitle":"Deploy staging %s","createdAt":"2026-07-14T00:00:01Z","url":"https://example.test/runs/11"}]\n' "$NEW_SHA"
    return 0
  fi
  if [ "$1" = api ] && [[ "$2" == *'/compare/'* ]]; then printf 'ahead\n'; return 0; fi
  return 1
}
wrong_environment="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; wrong_environment_rc=$?
check 'different-environment run evidence blocks inclusion' 1 "$wrong_environment_rc"
check 'different-environment evidence reports blocked' blocked "$(printf '%s' "$wrong_environment" | jq -r .outcome)"

gh() {
  if [ "$1" = api ] && [[ "$2" == *'/runs?'* ]]; then
    printf '[{"databaseId":12,"status":"completed","conclusion":"success","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:02Z","url":"https://example.test/runs/12"},{"databaseId":10,"status":"completed","conclusion":"success","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:00Z","url":"https://example.test/runs/10"}]\n' "$NEW_SHA" "$NEW_SHA"
    return 0
  fi
  if [ "$1" = api ] && [[ "$2" == *'/compare/'* ]]; then printf 'ahead\n'; return 0; fi
  return 1
}
duplicate="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; duplicate_rc=$?
check 'duplicate successful runs for live SHA are idempotent' 0 "$duplicate_rc"
check 'newest duplicate run supplies inclusion proof' 12 "$(printf '%s' "$duplicate" | jq -r .run_id)"

DUPLICATE_RUNS="$(printf '[{"databaseId":13,"status":"completed","conclusion":"cancelled","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:03Z","url":"https://example.test/runs/13"},{"databaseId":10,"status":"completed","conclusion":"success","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:00Z","url":"https://example.test/runs/10"}]' "$NEW_SHA" "$NEW_SHA")"
gh() {
  if [ "$1" = api ] && [[ "$2" == *'/runs?'* ]]; then printf '%s\n' "$DUPLICATE_RUNS"; return 0; fi
  if [ "$1" = api ] && [[ "$2" == *'/compare/'* ]]; then printf 'ahead\n'; return 0; fi
  return 1
}
successful_then_cancelled="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; successful_then_cancelled_rc=$?
check 'newer cancelled duplicate does not hide older successful run' 0 "$successful_then_cancelled_rc"
check 'older successful duplicate supplies proof' 10 "$(printf '%s' "$successful_then_cancelled" | jq -r .run_id)"

DUPLICATE_RUNS="$(printf '[{"databaseId":10,"status":"completed","conclusion":"success","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:00Z","url":"https://example.test/runs/10"},{"databaseId":13,"status":"completed","conclusion":"cancelled","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:03Z","url":"https://example.test/runs/13"}]' "$NEW_SHA" "$NEW_SHA")"
reversed_duplicates="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; reversed_duplicates_rc=$?
check 'duplicate selection is independent of API order' 0 "$reversed_duplicates_rc"
check 'reversed fixture still chooses successful proof' 10 "$(printf '%s' "$reversed_duplicates" | jq -r .run_id)"

MATERIAL_SHA_A=ccccccccccccccccccccccccccccccccccccccc1
MATERIAL_SHA_B=ccccccccccccccccccccccccccccccccccccccc2
DUPLICATE_RUNS="$(printf '[{"databaseId":14,"status":"completed","conclusion":"success","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:04Z","url":"https://example.test/runs/14"},{"databaseId":15,"status":"completed","conclusion":"success","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:05Z","url":"https://example.test/runs/15"}]' "$MATERIAL_SHA_A" "$MATERIAL_SHA_B")"
curl() { printf '{"commit":"ccccccc"}\n'; }
ambiguous="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; ambiguous_rc=$?
check 'materially different live-prefix candidates fail ambiguous' 1 "$ambiguous_rc"
check 'materially different candidates report ambiguity' ambiguous-verified-successors "$(printf '%s' "$ambiguous" | jq -r .reason)"

curl() { printf '{"commit":"cccccccccccccccccccccccccccccccccccccccc"}\n'; }
stale="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; stale_rc=$?
check 'stale runtime blocks inclusion' 1 "$stale_rc"
check 'stale runtime outcome is blocked' blocked "$(printf '%s' "$stale" | jq -r .outcome)"

DUPLICATE_RUNS="$(printf '[{"databaseId":12,"status":"completed","conclusion":"success","displayTitle":"Deploy production %s","createdAt":"2026-07-14T00:00:02Z","url":"https://example.test/runs/12"}]' "$NEW_SHA")"

CANCEL_LEDGER="$TMP/cancelled-ledger"
mkdir -p "$CANCEL_LEDGER"
export OTTA_LEDGER_DIR="$CANCEL_LEDGER"
cancel_key="$(workflow_deploy_key acme/widget deploy.yml production "$OLD_SHA")"
append_deploy_record acme/widget deploy_workflow_failed "$cancel_key" \
  "$(jq -cn --arg sha "$OLD_SHA" '{workflow:"deploy.yml",ref:"main",sha:$sha,target:"production"}')" \
  '{"run_id":9,"conclusion":"cancelled"}' >/dev/null
curl() { printf '{"commit":"%s"}\n' "$NEW_SHA"; }
run_github_workflow_deploy acme/widget acme/widget production deploy.yml main sha \
  "$OLD_SHA" https://example.test/health commit >/dev/null 2>&1; resumed_rc=$?
check 'cancelled older release resumes through verified descendant' 0 "$resumed_rc"
check 'cancelled older release records included' deploy_included \
  "$(deployment_last_record acme/widget "$cancel_key" | jq -r .event)"
unset -f gh curl

echo "  → $((30 - failures)) passed, $failures failed"
[ "$failures" -eq 0 ]
