#!/usr/bin/env bash
# otta-deploy-verify.sh — post-merge deploy+verify stage for the Otta loop (#20).
#
# Drives a green PR through to deployment per the repo's `.otta.yml` `deploy`
# policy. The four phases:
#   1. parse  — read the `deploy` block, default to `human-approve` when absent.
#   2. poll   — wait for every Otta Gate sub-check to go green, or surface the
#               blocking sub-check (esp. a CI check with no runner) instead of
#               hanging silently.
#   3. merge  — only when policy allows AND every sub-check is green.
#   4. verify — confirm the deploy reached the merged SHA (provider SHA-match),
#               optionally probe a health endpoint, and report URL + SHA.
#
# Universal-tool rule: NO hardcoded provider creds or infra. The Coolify adapter
# reads everything from the environment; `provider: none` is the generic path.
#
# The pure decision functions (parse_deploy_*, decide_merge, sha_match,
# poll_blocker) are sourced and unit-tested by tests/otta-deploy-verify*.test.sh
# with fixtures — no live `gh`/Coolify call in tests.
#
# Usage:
#   bash otta-deploy-verify.sh <pr-number> [--otta-yml <path>]
#   # or source it to call the individual functions in tests.
#
# Strict mode is applied only when executed directly (see the dispatch guard at
# the bottom) so that sourcing this file for its functions does not leak `set
# -e` into the caller's shell.

_deploy_verify_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/github-workflow-deploy.sh
[ -f "$_deploy_verify_dir/github-workflow-deploy.sh" ] && . "$_deploy_verify_dir/github-workflow-deploy.sh"

# ===========================================================================
# Policy parsing (pure — reads a .otta.yml path, echoes the resolved value)
# ===========================================================================

# Read a scalar from the `deploy:` block of an .otta.yml file using awk (no yq
# dependency — yq isn't universal). Returns empty string if absent.
_deploy_raw() {
  # $1 = yml path, $2 = key under deploy:
  local yml="$1" key="$2"
  [ -f "$yml" ] || { echo ""; return 0; }
  awk -v key="$key" '
    /^[^[:space:]#]/ { in_deploy = ($0 ~ /^deploy:/) }
    in_deploy && $0 ~ "^[[:space:]]+" key ":" {
      sub("^[[:space:]]+" key ":[[:space:]]*", "")
      sub(/[[:space:]]*#.*$/, "")          # strip trailing comment
      gsub(/^["'"'"']|["'"'"']$/, "")      # strip surrounding quotes
      gsub(/[[:space:]]+$/, "")            # strip trailing ws
      print; exit
    }
  ' "$yml"
}

# deploy.auto — default human-approve when absent (back-compat: existing repos
# with no deploy block are NEVER merged automatically).
parse_deploy_auto() {
  local v; v="$(_deploy_raw "${1:-.otta.yml}" auto)"
  case "$v" in
    merge-on-green|merge-and-deploy|human-approve) echo "$v" ;;
    *) echo "human-approve" ;;   # absent / unknown → safe default
  esac
}

parse_deploy_target()   { local v; v="$(_deploy_raw "${1:-.otta.yml}" target)";   echo "${v:-production}"; }
parse_deploy_provider() { local v; v="$(_deploy_raw "${1:-.otta.yml}" provider)"; echo "${v:-none}"; }
parse_deploy_verify()   { local v; v="$(_deploy_raw "${1:-.otta.yml}" verify)";   echo "${v:-sha-match}"; }
parse_deploy_executor() { local v; v="$(_deploy_raw "${1:-.otta.yml}" executor)"; echo "${v:-none}"; }
parse_deploy_workflow() { _deploy_raw "${1:-.otta.yml}" workflow; }
parse_deploy_ref() { local v; v="$(_deploy_raw "${1:-.otta.yml}" ref)"; echo "${v:-main}"; }
parse_deploy_sha_input() { local v; v="$(_deploy_raw "${1:-.otta.yml}" sha_input)"; echo "${v:-commit_sha}"; }
parse_deploy_health_url() { _deploy_raw "${1:-.otta.yml}" health_url; }
parse_deploy_health_commit_field() {
  local v; v="$(_deploy_raw "${1:-.otta.yml}" health_commit_field)"; echo "${v:-commit}"
}

# AC5: production + merge-and-deploy requires explicit per-repo opt-in. The
# opt-in key is `deploy.allow_production: true`. Without it, the policy is
# REJECTED so no one ships hands-off to prod by accident.
parse_deploy_allow_production() {
  local v; v="$(_deploy_raw "${1:-.otta.yml}" allow_production)"
  [ "$v" = "true" ] && echo "true" || echo "false"
}

# ===========================================================================
# Policy decision (pure)
# ===========================================================================

# decide_merge <auto> <all_green> [target] [allow_production]
#   echoes:  merge        — policy allows the merge
#            no-merge      — human-approve, or gate not green
#            blocked-prod  — prod + merge-and-deploy without opt-in (AC5)
#   returns: 0 for merge, 1 otherwise.
decide_merge() {
  local auto="$1" all_green="$2" target="${3:-production}" allow_prod="${4:-false}"

  if [ "$auto" = "human-approve" ]; then echo "no-merge"; return 1; fi

  # AC5 guard: prod hands-off needs explicit opt-in, checked BEFORE green so the
  # misconfiguration surfaces even on a green gate.
  if [ "$auto" = "merge-and-deploy" ] && [ "$target" = "production" ] && [ "$allow_prod" != "true" ]; then
    echo "blocked-prod"; return 1
  fi

  if [ "$all_green" != "true" ]; then echo "no-merge"; return 1; fi

  case "$auto" in
    merge-on-green|merge-and-deploy) echo "merge"; return 0 ;;
    *) echo "no-merge"; return 1 ;;
  esac
}

# decide_delivery_action <auto> <pr-state> <executor> <approved-head> <head> <green>
# Pure transition table for the workflow executor. Approval is commit-bound and
# authorizes merge/dispatch; it is not inferred from a green gate.
decide_delivery_action() {
  local auto="$1" state="$2" executor="$3" approved="${4:-}" head="${5:-}" green="${6:-false}"
  [ "$executor" = "github-workflow" ] || { echo "legacy"; return 0; }

  if [ "$auto" = "human-approve" ]; then
    [ -n "$approved" ] || { echo "wait-human"; return 1; }
    [ "$approved" = "$head" ] || { echo "invalid-approval"; return 2; }
    [ "$state" = "MERGED" ] && { echo "dispatch"; return 0; }
    [ "$state" = "OPEN" ] && [ "$green" = "true" ] && { echo "merge-dispatch"; return 0; }
    echo "wait-gate"; return 1
  fi

  [ "$green" = "true" ] || { echo "wait-gate"; return 1; }
  [ "$auto" = "merge-on-green" ] && { echo "merge-only"; return 0; }
  [ "$auto" = "merge-and-deploy" ] && { echo "merge-dispatch"; return 0; }
  echo "legacy"
}

# ===========================================================================
# SHA-match verification (pure)
# ===========================================================================

# sha_match <expected> <actual> — true if the deployed SHA matches the merged
# SHA (prefix-tolerant: a 7-char short SHA matches its full form, either way).
sha_match() {
  local expected="$1" actual="$2"
  [ -n "$expected" ] && [ -n "$actual" ] || return 1
  case "$actual" in "$expected"*) return 0 ;; esac
  case "$expected" in "$actual"*) return 0 ;; esac
  return 1
}

# ===========================================================================
# Gate poll (reads check-run JSON from a stubbable source)
# ===========================================================================

# poll_blocker <check-runs-json>
#   Inspects the GitHub check-runs payload (the `.check_runs[]` array shape from
#   `gh api .../check-runs`). Echoes:
#     green            — every check completed + success (clear to merge)
#     <name>: <reason> — the first blocking sub-check, with the reason. A check
#                        that is queued/in-progress with NO runner attached (the
#                        dead self-hosted-runner case) is reported explicitly so
#                        the loop never hangs silently.
#   returns 0 when green, 1 when blocked.
poll_blocker() {
  local json="$1"
  command -v python3 >/dev/null 2>&1 || { echo "error: python3 required to parse check-runs"; return 2; }
  python3 - "$json" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
runs = data.get("check_runs", data) if isinstance(data, dict) else data
blocker = None
all_green = True
for r in runs:
    name = r.get("name", "?")
    status = r.get("status", "")          # queued | in_progress | completed
    concl = r.get("conclusion")           # success | failure | None ...
    if status != "completed":
        all_green = False
        # No runner has picked it up → stuck. Surface, don't hang.
        reason = "stuck — no runner has picked up this check" if status == "queued" \
                 else f"still {status}"
        blocker = blocker or f"{name}: {reason}"
        continue
    if concl != "success":
        all_green = False
        blocker = blocker or f"{name}: {concl or 'not success'}"
if all_green:
    print("green"); sys.exit(0)
print(blocker or "blocked: unknown"); sys.exit(1)
PY
}

# ===========================================================================
# Deploy self-audit (issue #100) — pre-ready checks before declaring deploy-ready
# ===========================================================================

# _audit_incident <repo> <pr> <finding> <detail>
#   Appends one structured incident line to ~/.otta/ledger/<repo-slug>.jsonl.
#   Uses `engine incident` CLI when available; falls back to plain jsonl append.
_audit_incident() {
  local repo="${1:-}" pr="${2:-}" finding="${3:-unknown}" detail="${4:-}"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')"
  local slug="${repo//\//-}"
  local ledger_dir="${OTTA_LEDGER_DIR:-${HOME}/.otta/ledger}"
  mkdir -p "$ledger_dir"
  printf '{"ts":"%s","source":"deploy_audit","repo":"%s","pr":"%s","finding":"%s","detail":"%s"}\n' \
    "$now" "$repo" "$pr" "$finding" "$detail" >> "${ledger_dir}/${slug}.jsonl"
}

# self_audit <check-runs-json> [repo] [pr-number]
#   Answers the 4 pre-deploy readiness questions, logging evidence for each:
#     Q1: any green check actually skipped/neutral? (AC2: green-but-skipped)
#     Q2: /health commit == PR head SHA? (when OTTA_DEPLOY_HEALTH_URL + expected SHA set)
#     Q3: aggregate gate stale vs its children?
#     Q4: required connectors (Pulse) reachable?
#   Returns 0 if all pass, 1 if any finding. Findings append to the ledger (AC3).
self_audit() {
  local json="$1" repo="${2:-}" pr="${3:-}"
  local found=0

  command -v python3 >/dev/null 2>&1 || { echo "deploy-audit: skip — python3 unavailable"; return 0; }

  # Q1 — green-but-skipped: skipped/neutral conclusions are NOT truly passing.
  local skipped_names
  skipped_names="$(python3 - "$json" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
runs = data.get("check_runs", data) if isinstance(data, dict) else data
names = [r.get("name","?") for r in runs
         if r.get("conclusion") in ("skipped", "neutral", "stale")]
print(", ".join(names))
PY
)" || skipped_names=""
  if [ -n "$skipped_names" ]; then
    echo "deploy-audit: WARN Q1 — green-but-skipped checks (NOT truly passing): $skipped_names" >&2
    _audit_incident "$repo" "$pr" "green-but-skipped" "$skipped_names"
    found=1
  else
    echo "deploy-audit: ok Q1 — no skipped/neutral checks"
  fi

  # Q2 — /health SHA match (when health URL + expected SHA are both available).
  local expected_sha="${OTTA_AUDIT_EXPECTED_SHA:-}"
  if [ -n "${OTTA_DEPLOY_HEALTH_URL:-}" ] && [ -n "$expected_sha" ]; then
    local health_body health_sha
    health_body="$(curl -fsS -m 5 "${OTTA_DEPLOY_HEALTH_URL}" 2>/dev/null || true)"
    health_sha="$(printf '%s' "$health_body" | python3 -c \
      'import json,sys; d=json.load(sys.stdin); print(d.get("commit",d.get("sha",d.get("version",""))))' 2>/dev/null || true)"
    if [ -n "$health_sha" ] && ! sha_match "$expected_sha" "$health_sha"; then
      echo "deploy-audit: WARN Q2 — /health SHA mismatch: expected $expected_sha, got $health_sha" >&2
      _audit_incident "$repo" "$pr" "health-sha-mismatch" "expected:$expected_sha got:$health_sha"
      found=1
    else
      echo "deploy-audit: ok Q2 — /health SHA ok (expected=$expected_sha actual=${health_sha:-<not checked>})"
    fi
  else
    echo "deploy-audit: skip Q2 — /health check not configured (set OTTA_DEPLOY_HEALTH_URL + OTTA_AUDIT_EXPECTED_SHA)"
  fi

  # Q3 — stale aggregate: the aggregate gate check should be at least as recent as its children.
  local stale_children
  stale_children="$(python3 - "$json" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
runs = data.get("check_runs", data) if isinstance(data, dict) else data
agg = next((r for r in runs
            if "otta" in r.get("name","").lower() and "gate" in r.get("name","").lower()), None)
if not agg:
    print("")
    sys.exit(0)
agg_ts = agg.get("completed_at") or agg.get("started_at") or ""
stale = [r.get("name","?") for r in runs
         if r is not agg and (r.get("completed_at","") or "") > agg_ts and r.get("completed_at")]
print(", ".join(stale))
PY
)" || stale_children=""
  if [ -n "$stale_children" ]; then
    echo "deploy-audit: WARN Q3 — aggregate gate may be stale vs children: $stale_children" >&2
    _audit_incident "$repo" "$pr" "stale-aggregate" "$stale_children"
    found=1
  else
    echo "deploy-audit: ok Q3 — aggregate gate not stale vs children"
  fi

  # Q4 — connector availability: Pulse reachable when configured.
  if [ -n "${OTTA_PULSE_URL:-}" ]; then
    if curl -fsS -m 5 "${OTTA_PULSE_URL%/}/health" >/dev/null 2>&1; then
      echo "deploy-audit: ok Q4 — Pulse connector reachable (${OTTA_PULSE_URL%/}/health)"
    else
      echo "deploy-audit: WARN Q4 — Pulse connector unreachable at ${OTTA_PULSE_URL%/}/health" >&2
      _audit_incident "$repo" "$pr" "connector-unreachable" "pulse:${OTTA_PULSE_URL%/}/health"
      found=1
    fi
  else
    echo "deploy-audit: skip Q4 — Pulse connector check not configured (OTTA_PULSE_URL unset)"
  fi

  return "$found"
}

# ===========================================================================
# Provider deploy verification (pluggable adapters — env-driven, no hardcoding)
# ===========================================================================

# verify_deploy <provider> <expected-sha> <verify-mode>
#   provider: coolify | none.  Coolify reads OTTA_COOLIFY_* from the env. The
#   `none` provider is the generic path (no SHA source → reports skipped).
#   This wraps the live calls; tests exercise sha_match / poll_blocker directly.
verify_deploy() {
  local provider="$1" expected="$2" mode="${3:-sha-match}"
  case "$provider" in
    coolify)
      # Coolify adapter — all config from env (universal-tool rule). The caller
      # (ship.md / a CI job) provides creds; nothing is baked into the plugin.
      local base="${OTTA_COOLIFY_URL:-}" token="${OTTA_COOLIFY_TOKEN:-}" app="${OTTA_COOLIFY_APP_UUID:-}"
      if [ -z "$base" ] || [ -z "$token" ] || [ -z "$app" ]; then
        echo "deploy-verify: coolify provider needs OTTA_COOLIFY_URL / _TOKEN / _APP_UUID in the env" >&2
        return 2
      fi
      # Poll until the deployed SHA matches the merged SHA or timeout. Status
      # lines are throttled to at most once per 60s of elapsed wait (still
      # printed on the very first tick) so a long poll doesn't spam the log.
      local actual sha_timeout="${OTTA_SHA_POLL_TIMEOUT:-120}" sha_interval=10 sha_waited=0 sha_last_print=-60
      while :; do
        actual="$(curl -fsS -H "Authorization: Bearer $token" \
          "$base/api/v1/deployments?uuid=$app" 2>/dev/null \
          | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d[0].get("commit") if isinstance(d,list) and d else d.get("commit","")) or "")' 2>/dev/null || true)"
        if sha_match "$expected" "$actual"; then
          echo "deploy-verify: coolify SHA-match ok ($actual)"
          break
        fi
        if [ "$sha_waited" -ge "$sha_timeout" ]; then
          echo "deploy-verify: coolify SHA mismatch after ${sha_timeout}s — expected $expected, deployed ${actual:-<none>}" >&2
          return 1
        fi
        if [ $((sha_waited - sha_last_print)) -ge 60 ]; then
          echo "deploy-verify: waiting for Coolify to record SHA (${sha_waited}s/${sha_timeout}s) — deployed ${actual:-<none>}"
          sha_last_print=$sha_waited
        fi
        sleep "$sha_interval"; sha_waited=$((sha_waited + sha_interval))
      done
      if [ "$mode" = "health" ] && [ -n "${OTTA_DEPLOY_HEALTH_URL:-}" ]; then
        curl -fsS "$OTTA_DEPLOY_HEALTH_URL" >/dev/null 2>&1 \
          && echo "deploy-verify: health probe ok ($OTTA_DEPLOY_HEALTH_URL)" \
          || { echo "deploy-verify: health probe FAILED ($OTTA_DEPLOY_HEALTH_URL)" >&2; return 1; }
      fi
      ;;
    none|"")
      echo "deploy-verify: provider 'none' — generic path, no automated SHA verification"
      ;;
    *)
      echo "deploy-verify: unknown provider '$provider' (supported: coolify, none)" >&2
      return 2
      ;;
  esac
}

# ===========================================================================
# Orchestration (only runs when executed, not when sourced)
# ===========================================================================

_run() {
  local pr="${1:-}" yml=".otta.yml" approved_head="" retry_failed="false" resolve_run_id=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --otta-yml) yml="$2"; shift 2 ;;
      --approved-head) approved_head="$2"; shift 2 ;;
      --retry-failed-run) retry_failed="true"; shift ;;
      --resolve-run-id) resolve_run_id="$2"; shift 2 ;;
      *) echo "unknown arg: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$pr" ] || { echo "usage: otta-deploy-verify.sh <pr-number> [--otta-yml <path>] [--approved-head <sha>] [--retry-failed-run] [--resolve-run-id <id>]" >&2; return 1; }

  local gh_repo
  gh_repo="$(git remote get-url origin 2>/dev/null | sed 's|.*github\.com[:/]\(.*\)\.git$|\1|;s|.*github\.com[:/]\(.*\)$|\1|')"
  [ -n "$gh_repo" ] || { echo "deploy: cannot determine repo from git remote origin" >&2; return 1; }

  local auto target provider verify allow_prod executor workflow workflow_ref sha_input health_url health_field
  auto="$(parse_deploy_auto "$yml")"
  target="$(parse_deploy_target "$yml")"
  provider="$(parse_deploy_provider "$yml")"
  verify="$(parse_deploy_verify "$yml")"
  allow_prod="$(parse_deploy_allow_production "$yml")"
  executor="$(parse_deploy_executor "$yml")"
  workflow="$(parse_deploy_workflow "$yml")"
  workflow_ref="$(parse_deploy_ref "$yml")"
  sha_input="$(parse_deploy_sha_input "$yml")"
  health_url="$(parse_deploy_health_url "$yml")"
  health_field="$(parse_deploy_health_commit_field "$yml")"

  echo "deploy policy: auto=$auto target=$target executor=$executor provider=$provider verify=$verify"

  local pr_json pr_state pr_head merge_sha
  if [ "$executor" = "github-workflow" ]; then
    [ -n "$workflow" ] || { echo "deploy: github-workflow executor requires deploy.workflow" >&2; return 1; }
    [ -n "$health_url" ] || { echo "deploy: github-workflow executor requires deploy.health_url" >&2; return 1; }
    pr_json="$(gh pr view "$pr" --repo "$gh_repo" --json state,headRefOid,mergeCommit 2>/dev/null)" || {
      echo "deploy: cannot read PR #$pr state" >&2; return 1;
    }
    pr_state="$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state", ""))')"
    pr_head="$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("headRefOid", ""))')"
    merge_sha="$(printf '%s' "$pr_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("mergeCommit") or {}).get("oid", ""))')"

    if [ "$auto" = "human-approve" ] && [ -z "$approved_head" ]; then
      echo "deploy: production approval required — repo=$gh_repo PR=#$pr head=$pr_head target=$target workflow=$workflow ref=$workflow_ref health=${health_url:-<none>}" >&2
      echo "deploy: rerun with --approved-head $pr_head after explicit human approval" >&2
      return 1
    fi
    if [ "$auto" = "human-approve" ] && [ "$approved_head" != "$pr_head" ]; then
      echo "deploy: invalid approval — approved head $approved_head does not match current head $pr_head" >&2
      return 1
    fi

    # A previously merged PR can resume dispatch/verification without polling
    # an open-PR gate or attempting a second merge.
    if [ "$pr_state" = "MERGED" ]; then
      local merged_action
      merged_action="$(decide_delivery_action "$auto" "$pr_state" "$executor" "$approved_head" "$pr_head" true)" || true
      if [ "$merged_action" = "merge-only" ]; then
        echo "deploy: PR #$pr is already merged; auto=merge-on-green performs no deployment."
        return 0
      fi
      [ "$merged_action" = "dispatch" ] || [ "$merged_action" = "merge-dispatch" ] || {
        echo "deploy: policy does not authorize post-merge dispatch ($merged_action)" >&2; return 1;
      }
      [ -n "$merge_sha" ] || { echo "deploy: merged PR #$pr has no merge commit SHA" >&2; return 1; }
      OTTA_DEPLOY_RETRY_FAILED_RUN="$retry_failed" OTTA_DEPLOY_RESOLVE_RUN_ID="$resolve_run_id" \
        run_github_workflow_deploy "$gh_repo" "$gh_repo" "$target" "$workflow" \
        "$workflow_ref" "$sha_input" "$merge_sha" "$health_url" "$health_field"
      return $?
    fi
    [ "$pr_state" = "OPEN" ] || { echo "deploy: unsupported PR state '$pr_state'" >&2; return 1; }
  fi

  # human-approve preserves today's behavior: stop at the green PR.
  if [ "$auto" = "human-approve" ] && [ "$executor" != "github-workflow" ]; then
    echo "deploy: auto=human-approve → stopping at the open PR (human merges). No merge, no deploy."
    return 0
  fi

  # AC5: reject prod hands-off without explicit opt-in BEFORE touching the gate.
  local pre; pre="$(decide_merge "$auto" "false" "$target" "$allow_prod")" || true
  if [ "$pre" = "blocked-prod" ]; then
    echo "deploy: BLOCKED — target=production with auto=merge-and-deploy requires 'deploy.allow_production: true' in .otta.yml (no accidental hands-off prod deploys)." >&2
    return 1
  fi

  # Poll the Otta Gate until green or timeout; surface the blocker on stall.
  # Status lines are throttled to at most once per 60s of elapsed wait (still
  # printed on the very first tick) so a long poll doesn't spam the log.
  local timeout="${OTTA_DEPLOY_POLL_TIMEOUT:-600}" interval="${OTTA_DEPLOY_POLL_INTERVAL:-15}"
  local waited=0 status_json result last_print=-60
  while :; do
    status_json="$(gh pr checks "$pr" --repo "$gh_repo" --json name,state 2>/dev/null \
      | python3 -c 'import json,sys; rows=json.load(sys.stdin); print(json.dumps({"check_runs":[{"name":r["name"],"status":"completed" if r["state"] in ("SUCCESS","FAILURE","ERROR") else "queued","conclusion":{"SUCCESS":"success","FAILURE":"failure","ERROR":"failure"}.get(r["state"])} for r in rows]}))' 2>/dev/null || echo '{"check_runs":[]}')"
    result="$(poll_blocker "$status_json")" && break
    if [ "$waited" -ge "$timeout" ]; then
      echo "deploy: gate did NOT go green within ${timeout}s — blocking sub-check → $result" >&2
      return 1
    fi
    if [ $((waited - last_print)) -ge 60 ]; then
      echo "deploy: waiting for gate ($result) — ${waited}s/${timeout}s"
      last_print=$waited
    fi
    sleep "$interval"; waited=$((waited + interval))
  done
  echo "deploy: gate green — all sub-checks passed."

  # Self-audit: 4 pre-ready checks before declaring deploy-ready (#100).
  # Runs after gate is green; a finding logs an incident but does NOT block the
  # merge (audit is advisory — the gate is the authoritative readiness signal).
  self_audit "$status_json" "$gh_repo" "$pr" || \
    echo "deploy: self-audit found issues (logged to ledger); merge proceeding per gate verdict."

  if [ "$executor" = "github-workflow" ]; then
    # Re-read the head immediately before mutation. Approval is invalidated by
    # any push that happened while checks were being polled.
    pr_json="$(gh pr view "$pr" --repo "$gh_repo" --json state,headRefOid,mergeCommit 2>/dev/null)" || {
      echo "deploy: cannot refresh PR #$pr before merge" >&2; return 1;
    }
    pr_state="$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state", ""))')"
    pr_head="$(printf '%s' "$pr_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("headRefOid", ""))')"
    if [ "$auto" = "human-approve" ] && [ "$approved_head" != "$pr_head" ]; then
      echo "deploy: invalid approval after gate — approved head $approved_head does not match current head $pr_head" >&2
      return 1
    fi

    local workflow_action
    workflow_action="$(decide_delivery_action "$auto" "$pr_state" "$executor" "$approved_head" "$pr_head" true)" || true
    case "$workflow_action" in
      merge-only|merge-dispatch)
        gh pr merge "$pr" --repo "$gh_repo" --squash --delete-branch >&2 || {
          echo "deploy: merge failed" >&2; return 1;
        }
        merge_sha="$(gh pr view "$pr" --repo "$gh_repo" --json mergeCommit -q '.mergeCommit.oid' 2>/dev/null || true)"
        [ -n "$merge_sha" ] || { echo "deploy: merge succeeded but merge SHA is unavailable" >&2; return 1; }
        echo "deploy: merged PR #$pr at $merge_sha."
        ;;
      dispatch)
        merge_sha="$(printf '%s' "$pr_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("mergeCommit") or {}).get("oid", ""))')"
        ;;
      *) echo "deploy: policy does not authorize workflow delivery ($workflow_action)" >&2; return 1 ;;
    esac
    if [ "$workflow_action" = "merge-only" ]; then
      echo "deploy: auto=merge-on-green → merged without workflow dispatch."
      return 0
    fi
    OTTA_DEPLOY_RETRY_FAILED_RUN="$retry_failed" OTTA_DEPLOY_RESOLVE_RUN_ID="$resolve_run_id" \
      run_github_workflow_deploy "$gh_repo" "$gh_repo" "$target" "$workflow" \
      "$workflow_ref" "$sha_input" "$merge_sha" "$health_url" "$health_field"
    return $?
  fi

  # Decide + merge.
  local decision; decision="$(decide_merge "$auto" "true" "$target" "$allow_prod")" || true
  if [ "$decision" != "merge" ]; then
    echo "deploy: policy does not authorize merge ($decision)." >&2
    return 1
  fi
  gh pr merge "$pr" --repo "$gh_repo" --squash --delete-branch >&2 || { echo "deploy: merge failed" >&2; return 1; }
  merge_sha="$(gh pr view "$pr" --repo "$gh_repo" --json mergeCommit -q '.mergeCommit.oid' 2>/dev/null || true)"
  echo "deploy: merged PR #$pr at ${merge_sha:-<unknown sha>}."

  if [ "$auto" = "merge-on-green" ]; then
    echo "deploy: auto=merge-on-green → merged; downstream deploy is handled outside Otta. Done."
    return 0
  fi

  # merge-and-deploy → verify the deploy reached the merged SHA.
  verify_deploy "$provider" "$merge_sha" "$verify"
}

# Only orchestrate when executed directly; sourcing exposes the functions
# without applying strict mode to (or running anything in) the caller's shell.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  _run "$@"
fi
