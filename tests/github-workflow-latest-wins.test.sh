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

# Ten concurrent requests collapse to one active A and one latest pending J.
# Without an external durable eligibility source, no pending request is
# optimistically superseded.
included=0; superseded=0; blocked=0
for letter in B C D E F G H I; do
  outcome="$(classify_release_successor A production J production false queued ahead)"
  [ "$outcome" = superseded ] && superseded=$((superseded + 1))
  [ "$outcome" = blocked ] && blocked=$((blocked + 1))
done
outcome="$(classify_release_successor A production J production true runtime_verified ahead)"
[ "$outcome" = included ] && included=$((included + 1))
check 'B-I are coalesced without optimistic supersession' 0 "$superseded"
check 'B-I remain non-terminal until runtime proof' 8 "$blocked"
check 'verified J includes A' 1 "$included"

OLD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEW_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
RUN_STATE=queued
gh() {
  if [ "$1" = api ] && [[ "$2" == *'/runs?'* ]]; then
    printf '[{"databaseId":10,"status":"%s","conclusion":null,"displayTitle":"Deploy %s","createdAt":"2026-07-14T00:00:00Z","url":"https://example.test/runs/10"}]\n' "$RUN_STATE" "$NEW_SHA"
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
    printf '[{"databaseId":10,"status":"completed","conclusion":"success","displayTitle":"Deploy %s","createdAt":"2026-07-14T00:00:00Z","url":"https://example.test/runs/10"}]\n' "$NEW_SHA"
    return 0
  fi
  if [ "$1" = api ] && [[ "$2" == *'/compare/'* ]]; then printf 'ahead\n'; return 0; fi
  return 1
}
verified="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; verified_rc=$?
check 'verified descendant succeeds' 0 "$verified_rc"
check 'verified descendant is included' included "$(printf '%s' "$verified" | jq -r .outcome)"
check 'included proof carries descendant SHA' "$NEW_SHA" "$(printf '%s' "$verified" | jq -r .sha)"

curl() { printf '{"commit":"cccccccccccccccccccccccccccccccccccccccc"}\n'; }
stale="$(find_eligible_successor acme/widget deploy.yml main production "$OLD_SHA" https://example.test/health commit)"; stale_rc=$?
check 'stale runtime blocks inclusion' 1 "$stale_rc"
check 'stale runtime outcome is blocked' blocked "$(printf '%s' "$stale" | jq -r .outcome)"

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

echo "  → $((23 - failures)) passed, $failures failed"
[ "$failures" -eq 0 ]
