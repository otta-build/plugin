#!/usr/bin/env bash
# Non-mutating GitHub concurrency simulation: ten Otta controllers, one active
# provider mutation, one latest pending request, and verified descendant repair.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/github-workflow-deploy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }
check() { [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"; echo "  ✓ $1"; }

export OTTA_LEDGER_DIR="$TMP/ledger"
export OTTA_DISPATCH_RECONCILE_ATTEMPTS=1 OTTA_DISPATCH_RECONCILE_INTERVAL=0
RUNS="$TMP/runs.json"
COUNTER="$TMP/counter"
MUTATIONS="$TMP/provider-mutations"
RUNTIME_SHA_FILE="$TMP/runtime-sha"
printf '[]\n' > "$RUNS"
printf '100\n' > "$COUNTER"
: > "$MUTATIONS"
: > "$RUNTIME_SHA_FILE"

sha_for() { printf '%040x\n' "$1"; }
_github_actor() { echo alice; }
_workflow_now() { echo '2026-07-14T00:00:00Z'; }
_list_workflow_runs() { cat "$RUNS"; }

gh() {
  if [ "$1 $2" = 'workflow run' ]; then
    requested=""
    for arg in "$@"; do case "$arg" in sha=*) requested="${arg#sha=}" ;; esac; done
    [ -n "$requested" ] || return 2
    id="$(cat "$COUNTER")"; id=$((id + 1)); printf '%s\n' "$id" > "$COUNTER"
    pending_count="$(jq '[.[] | select(.status == "queued")] | length' "$RUNS")"
    if [ "$pending_count" -gt 0 ]; then
      jq '[.[] | if .status == "queued" then .status="completed" | .conclusion="cancelled" else . end]' "$RUNS" > "$RUNS.tmp"
      mv "$RUNS.tmp" "$RUNS"
    fi
    active_count="$(jq '[.[] | select(.status == "in_progress")] | length' "$RUNS")"
    [ "$active_count" -eq 0 ] && state=in_progress || state=queued
    jq --argjson id "$id" --arg state "$state" --arg sha "$requested" \
      '. + [{databaseId:$id,status:$state,conclusion:null,createdAt:"2999-01-01T00:00:00Z",headSha:"main-ref",displayTitle:("Deploy production " + $sha),actor:"alice",url:("https://example.test/runs/" + ($id|tostring))}]' \
      "$RUNS" > "$RUNS.tmp"
    mv "$RUNS.tmp" "$RUNS"
    if [ "$state" = in_progress ]; then printf 'start %s\n' "$requested" >> "$MUTATIONS"; fi
    return 0
  fi
  if [ "$1 $2" = 'run view' ]; then
    id="$3"
    jq -c --argjson id "$id" '.[] | select(.databaseId == $id) | {status,conclusion,url,headSha}' "$RUNS"
    return 0
  fi
  if [ "$1" = api ] && [[ "$2" == *'/compare/'* ]]; then echo ahead; return 0; fi
  return 1
}
curl() { printf '{"commit":"%s"}\n' "$(cat "$RUNTIME_SHA_FILE")"; }

SHAS=""
for n in 1 2 3 4 5 6 7 8 9 10; do
  sha="$(sha_for "$n")"
  SHAS="$SHAS $sha"
  ensure_workflow_dispatched acme/widget acme/widget production deploy.yml main sha "$sha" >/dev/null
done

check 'ten dispatch requests recorded' 10 "$(jq length "$RUNS")"
check 'one provider mutation is active' 1 "$(jq '[.[] | select(.status == "in_progress")] | length' "$RUNS")"
check 'only latest request remains pending' 1 "$(jq '[.[] | select(.status == "queued")] | length' "$RUNS")"
check 'eight intermediate pending requests coalesced' 8 "$(jq '[.[] | select(.conclusion == "cancelled")] | length' "$RUNS")"

A_SHA="$(sha_for 1)"; J_SHA="$(sha_for 10)"
check 'A is active' "$A_SHA" "$(jq -r '.[] | select(.status == "in_progress") | .displayTitle | split(" ")[-1]' "$RUNS")"
check 'J is pending' "$J_SHA" "$(jq -r '.[] | select(.status == "queued") | .displayTitle | split(" ")[-1]' "$RUNS")"

# Finish A before starting J; the mutation log proves no overlap.
printf '%s\n' "$A_SHA" > "$RUNTIME_SHA_FILE"
jq --arg sha "$A_SHA" '[.[] | if (.displayTitle | endswith($sha)) then .status="completed" | .conclusion="success" else . end]' "$RUNS" > "$RUNS.tmp"; mv "$RUNS.tmp" "$RUNS"
run_github_workflow_deploy acme/widget acme/widget production deploy.yml main sha "$A_SHA" https://example.test/health commit >/dev/null
printf 'end %s\n' "$A_SHA" >> "$MUTATIONS"
jq --arg sha "$J_SHA" '[.[] | if (.displayTitle | endswith($sha)) then .status="in_progress" else . end]' "$RUNS" > "$RUNS.tmp"; mv "$RUNS.tmp" "$RUNS"
printf 'start %s\n' "$J_SHA" >> "$MUTATIONS"

printf '%s\n' "$J_SHA" > "$RUNTIME_SHA_FILE"
jq --arg sha "$J_SHA" '[.[] | if (.displayTitle | endswith($sha)) then .status="completed" | .conclusion="success" else . end]' "$RUNS" > "$RUNS.tmp"; mv "$RUNS.tmp" "$RUNS"
run_github_workflow_deploy acme/widget acme/widget production deploy.yml main sha "$J_SHA" https://example.test/health commit >/dev/null
printf 'end %s\n' "$J_SHA" >> "$MUTATIONS"

EXPECTED_MUTATIONS="$(printf 'start %s\nend %s\nstart %s\nend %s' "$A_SHA" "$A_SHA" "$J_SHA" "$J_SHA")"
check 'provider mutations never overlap' "$EXPECTED_MUTATIONS" "$(cat "$MUTATIONS")"

# Resume B-I from durable cancelled records after J is live. Each becomes
# included by the same verified descendant; none is runtime-verified alone.
included_count=0
for n in 2 3 4 5 6 7 8 9; do
  sha="$(sha_for "$n")"
  key="$(workflow_deploy_key acme/widget deploy.yml production "$sha")"
  input="$(deployment_last_record acme/widget "$key" | jq -c .input)"
  run_id="$(deployment_last_record acme/widget "$key" | jq -r .output.run_id)"
  append_deploy_record acme/widget deploy_workflow_failed "$key" "$input" \
    "$(jq -cn --arg run_id "$run_id" '{run_id:($run_id|tonumber),conclusion:"cancelled"}')" >/dev/null
  run_github_workflow_deploy acme/widget acme/widget production deploy.yml main sha "$sha" https://example.test/health commit >/dev/null
  [ "$(deployment_last_record acme/widget "$key" | jq -r .event)" = deploy_included ] && included_count=$((included_count + 1))
done
check 'B-I included only after J runtime verification' 8 "$included_count"
check 'only A and J are individually runtime verified' 2 "$(jq -s '[.[] | select(.event == "deploy_runtime_verified")] | length' "$OTTA_LEDGER_DIR/acme-widget.jsonl")"

echo '✓ ten-request concurrency and verified-descendant integration'
