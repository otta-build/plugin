#!/usr/bin/env bash
# GitHub Actions deployment adapter for Otta (#137).
# Safe to source: strict mode is enabled only when executed directly.

_workflow_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workflow_deploy_key() {
  printf '%s\n' "$1|$2|$3|$4" | shasum -a 256 | awk '{print $1}'
}

deployment_last_record() {
  local project="$1" key="$2"
  local file="${OTTA_LEDGER_DIR:-$HOME/.otta/ledger}/${project//\//-}.jsonl"
  [ -f "$file" ] || return 1
  jq -c --arg key "$key" \
    'select(.source == "deploy" and .input.idempotency_key == $key)' "$file" | tail -1
}

append_deploy_record() {
  local project="$1" event="$2" key="$3" input="${4:-}" output="${5:-}"
  [ -n "$input" ] || input='{}'
  [ -n "$output" ] || output='{}'
  local enriched
  enriched="$(jq -cn --arg key "$key" --argjson input "$input" '$input + {idempotency_key:$key}')" || return 2
  OTTA_PULSE_URL="${OTTA_PULSE_URL:-}" OTTA_PULSE_TOKEN="${OTTA_PULSE_TOKEN:-}" \
    bash "$_workflow_script_dir/ledger-append.sh" \
      --source deploy --event "$event" --score 0 --feedback "$event" \
      --project "$project" --input "$enriched" --output "$output"
}

_list_workflow_runs() {
  local repo="$1" workflow="$2" ref="$3" sha="$4"
  gh run list --repo "$repo" --workflow "$workflow" --event workflow_dispatch \
    --branch "$ref" --commit "$sha" \
    --json databaseId,status,conclusion,createdAt,headSha,url
}

_run_ids_json() {
  jq -c '[.[] | (.databaseId | tostring)]'
}

# reconcile_workflow_dispatch <repo> <workflow> <ref> <sha> <pre-run-ids-json>
# Prints the unique unseen run id. Returns 3 when none appears, 4 if ambiguous.
reconcile_workflow_dispatch() {
  local repo="$1" workflow="$2" ref="$3" sha="$4" pre_ids="$5"
  local attempts="${OTTA_DISPATCH_RECONCILE_ATTEMPTS:-12}"
  local interval="${OTTA_DISPATCH_RECONCILE_INTERVAL:-5}"
  local attempt=1 runs unseen count
  while [ "$attempt" -le "$attempts" ]; do
    runs="$(_list_workflow_runs "$repo" "$workflow" "$ref" "$sha")" || return 3
    unseen="$(jq -c --argjson before "$pre_ids" \
      '[.[] | select((.databaseId | tostring) as $id | ($before | index($id) | not))]' <<<"$runs")" || return 3
    count="$(jq 'length' <<<"$unseen")"
    if [ "$count" -eq 1 ]; then
      jq -r '.[0].databaseId' <<<"$unseen"
      return 0
    fi
    if [ "$count" -gt 1 ]; then
      echo "deploy: ambiguous workflow correlation — $count unseen runs match workflow=$workflow ref=$ref sha=$sha" >&2
      return 4
    fi
    [ "$attempt" -lt "$attempts" ] && sleep "$interval"
    attempt=$((attempt + 1))
  done
  echo "deploy: dispatched workflow run not found; state remains dispatch_unknown and will not be redispatched" >&2
  return 3
}

_record_correlated_run() {
  local project="$1" key="$2" input="$3" run_id="$4"
  local output
  output="$(jq -cn --arg run_id "$run_id" '{run_id:($run_id|tonumber)}')"
  append_deploy_record "$project" deploy_dispatched "$key" "$input" "$output" >/dev/null
  printf '%s\n' "$run_id"
}

_workflow_sha_match() {
  local expected="$1" actual="$2"
  [ -n "$expected" ] && [ -n "$actual" ] || return 1
  case "$actual" in "$expected"*) return 0 ;; esac
  case "$expected" in "$actual"*) return 0 ;; esac
  return 1
}

# wait_for_workflow_terminal <repo> <project> <key> <input-json> <run-id> <expected-sha>
wait_for_workflow_terminal() {
  local repo="$1" project="$2" key="$3" input="$4" run_id="$5" expected_sha="$6"
  local timeout="${OTTA_WORKFLOW_POLL_TIMEOUT:-1800}"
  local interval="${OTTA_WORKFLOW_POLL_INTERVAL:-10}"
  local waited=0 last_print=-60 json status conclusion url head output

  while :; do
    json="$(gh run view "$run_id" --repo "$repo" --json status,conclusion,url,headSha 2>/dev/null)" || {
      echo "deploy: cannot read workflow run $run_id" >&2
      return 1
    }
    status="$(jq -r '.status // ""' <<<"$json")"
    conclusion="$(jq -r '.conclusion // ""' <<<"$json")"
    url="$(jq -r '.url // ""' <<<"$json")"
    head="$(jq -r '.headSha // ""' <<<"$json")"

    if [ "$status" = "completed" ]; then
      output="$(jq -cn --arg run_id "$run_id" --arg conclusion "$conclusion" \
        --arg url "$url" --arg head "$head" \
        '{run_id:($run_id|tonumber),conclusion:$conclusion,url:$url,head_sha:$head}')"
      if [ "$conclusion" = "success" ] && _workflow_sha_match "$expected_sha" "$head"; then
        append_deploy_record "$project" deploy_workflow_succeeded "$key" "$input" "$output" >/dev/null
        echo "deploy: workflow run $run_id succeeded ($url)" >&2
        return 0
      fi
      append_deploy_record "$project" deploy_workflow_failed "$key" "$input" "$output" >/dev/null
      if [ "$conclusion" = "success" ]; then
        echo "deploy: workflow run $run_id head mismatch — expected $expected_sha, observed ${head:-<none>}" >&2
      else
        echo "deploy: workflow run $run_id completed with ${conclusion:-unknown} ($url)" >&2
      fi
      return 1
    fi

    if [ "$waited" -ge "$timeout" ]; then
      echo "deploy: workflow run $run_id did not complete within ${timeout}s; retry will resume this run" >&2
      return 1
    fi
    if [ $((waited - last_print)) -ge 60 ]; then
      echo "deploy: waiting for workflow run $run_id (${status:-unknown}, ${waited}s/${timeout}s)" >&2
      last_print=$waited
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
}

# verify_health_sha <url> <top-level-json-field> <expected-sha>
verify_health_sha() {
  local url="$1" field="$2" expected="$3"
  local timeout="${OTTA_HEALTH_POLL_TIMEOUT:-300}"
  local interval="${OTTA_HEALTH_POLL_INTERVAL:-10}"
  local waited=0 body observed="" state="unavailable"
  while :; do
    body="$(curl -fsS --max-time 10 "$url" 2>/dev/null)" || body=""
    if [ -n "$body" ]; then
      observed="$(jq -r --arg field "$field" '.[$field] // empty' <<<"$body" 2>/dev/null || true)"
      if [ -n "$observed" ]; then
        state="$observed"
        if _workflow_sha_match "$expected" "$observed"; then
          echo "deploy: runtime health SHA verified ($observed)" >&2
          return 0
        fi
      else
        state="unavailable"
      fi
    else
      state="unavailable"
    fi
    if [ "$waited" -ge "$timeout" ]; then
      echo "deploy: health SHA verification failed after ${timeout}s — expected $expected, observed $state, url=$url" >&2
      return 1
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
}

# run_github_workflow_deploy <repo> <project> <target> <workflow> <ref>
#   <sha-input> <merge-sha> <health-url> <health-field>
run_github_workflow_deploy() {
  local repo="$1" project="$2" target="$3" workflow="$4" ref="$5"
  local sha_input="$6" merge_sha="$7" health_url="$8" health_field="$9"
  local key latest run_id input output
  key="$(workflow_deploy_key "$repo" "$workflow" "$target" "$merge_sha")"
  latest="$(deployment_last_record "$project" "$key" 2>/dev/null || true)"
  if [ -n "$latest" ] && [ "$(jq -r '.event' <<<"$latest")" = "deploy_runtime_verified" ]; then
    echo "deploy: runtime already verified for $merge_sha" >&2
    return 0
  fi

  run_id="$(ensure_workflow_dispatched "$repo" "$project" "$target" "$workflow" "$ref" "$sha_input" "$merge_sha")" || return $?
  latest="$(deployment_last_record "$project" "$key")" || return 1
  input="$(jq -c '.input' <<<"$latest")"
  if [ "$(jq -r '.event' <<<"$latest")" != "deploy_workflow_succeeded" ]; then
    wait_for_workflow_terminal "$repo" "$project" "$key" "$input" "$run_id" "$merge_sha" || return $?
  fi
  [ -n "$health_url" ] || { echo "deploy: github-workflow executor requires deploy.health_url" >&2; return 1; }
  verify_health_sha "$health_url" "$health_field" "$merge_sha" || return $?
  output="$(jq -cn --arg run_id "$run_id" --arg url "$health_url" --arg sha "$merge_sha" \
    '{run_id:($run_id|tonumber),health_url:$url,verified_sha:$sha}')"
  append_deploy_record "$project" deploy_runtime_verified "$key" "$input" "$output" >/dev/null
  echo "deploy: workflow and runtime verified for $merge_sha" >&2
}

# ensure_workflow_dispatched <repo> <project> <target> <workflow> <ref> <sha-input> <merge-sha>
# At-most-once under uncertainty: once dispatching is recorded, retries only
# reconcile/resume and never issue another workflow_dispatch implicitly.
ensure_workflow_dispatched() {
  local repo="$1" project="$2" target="$3" workflow="$4" ref="$5" sha_input="$6" merge_sha="$7"
  local key latest event run_id pre_runs pre_ids input
  key="$(workflow_deploy_key "$repo" "$workflow" "$target" "$merge_sha")"

  latest="$(deployment_last_record "$project" "$key" 2>/dev/null || true)"
  if [ -n "$latest" ]; then
    event="$(jq -r '.event' <<<"$latest")"
    case "$event" in
      deploy_runtime_verified|deploy_dispatched|deploy_workflow_succeeded)
        jq -r '.output.run_id' <<<"$latest"
        return 0
        ;;
      deploy_workflow_failed)
        if [ "${OTTA_DEPLOY_RETRY_FAILED_RUN:-false}" = "true" ]; then
          run_id="$(jq -r '.output.run_id // empty' <<<"$latest")"
          [ -n "$run_id" ] || { echo "deploy: failed record has no run id to retry" >&2; return 6; }
          gh run rerun "$run_id" --repo "$repo" --failed || {
            echo "deploy: explicit rerun request failed for workflow run $run_id" >&2; return 6;
          }
          input="$(jq -c '.input' <<<"$latest")"
          _record_correlated_run "$project" "$key" "$input" "$run_id"
          return $?
        fi
        echo "deploy: workflow previously failed for idempotency key $key; explicit recovery is required" >&2
        return 5
        ;;
      deploy_dispatching|deploy_dispatch_unknown)
        input="$(jq -c '.input' <<<"$latest")"
        pre_ids="$(jq -c '.input.pre_run_ids // []' <<<"$latest")"
        if [ -n "${OTTA_DEPLOY_RESOLVE_RUN_ID:-}" ]; then
          local resolved_json resolved_event resolved_head resolved_id
          resolved_json="$(gh run view "$OTTA_DEPLOY_RESOLVE_RUN_ID" --repo "$repo" \
            --json databaseId,event,headSha,url 2>/dev/null)" || {
            echo "deploy: cannot inspect manually selected run $OTTA_DEPLOY_RESOLVE_RUN_ID" >&2; return 6;
          }
          resolved_event="$(jq -r '.event // ""' <<<"$resolved_json")"
          resolved_head="$(jq -r '.headSha // ""' <<<"$resolved_json")"
          resolved_id="$(jq -r '.databaseId // empty' <<<"$resolved_json")"
          if [ "$resolved_event" != "workflow_dispatch" ] || ! _workflow_sha_match "$merge_sha" "$resolved_head"; then
            echo "deploy: selected run $OTTA_DEPLOY_RESOLVE_RUN_ID does not match event=workflow_dispatch and sha=$merge_sha" >&2
            return 6
          fi
          _record_correlated_run "$project" "$key" "$input" "$resolved_id"
          return $?
        fi
        run_id="$(reconcile_workflow_dispatch "$repo" "$workflow" "$ref" "$merge_sha" "$pre_ids")"
        case $? in
          0) _record_correlated_run "$project" "$key" "$input" "$run_id" ; return $? ;;
          4) return 4 ;;
          *)
            append_deploy_record "$project" deploy_dispatch_unknown "$key" "$input" '{}' >/dev/null
            return 3
            ;;
        esac
        ;;
      *)
        echo "deploy: unsupported recorded deployment state: $event" >&2
        return 6
        ;;
    esac
  fi

  pre_runs="$(_list_workflow_runs "$repo" "$workflow" "$ref" "$merge_sha")" || {
    echo "deploy: cannot snapshot workflow runs before dispatch" >&2; return 2;
  }
  pre_ids="$(printf '%s' "$pre_runs" | _run_ids_json)" || return 2
  input="$(jq -cn --arg workflow "$workflow" --arg ref "$ref" --arg sha "$merge_sha" \
    --arg sha_input "$sha_input" --arg target "$target" --argjson pre "$pre_ids" \
    '{workflow:$workflow,ref:$ref,sha:$sha,sha_input:$sha_input,target:$target,pre_run_ids:$pre}')"
  append_deploy_record "$project" deploy_dispatching "$key" "$input" '{}' >/dev/null || return 2

  if ! gh workflow run "$workflow" --repo "$repo" --ref "$ref" -f "$sha_input=$merge_sha"; then
    append_deploy_record "$project" deploy_dispatch_unknown "$key" "$input" '{}' >/dev/null
    echo "deploy: workflow dispatch returned an error; reconciliation is required before retry" >&2
    return 3
  fi

  run_id="$(reconcile_workflow_dispatch "$repo" "$workflow" "$ref" "$merge_sha" "$pre_ids")"
  case $? in
    0) _record_correlated_run "$project" "$key" "$input" "$run_id" ;;
    4) return 4 ;;
    *)
      append_deploy_record "$project" deploy_dispatch_unknown "$key" "$input" '{}' >/dev/null
      return 3
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  echo "source this adapter through otta-deploy-verify.sh" >&2
  exit 2
fi
