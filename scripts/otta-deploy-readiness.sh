#!/usr/bin/env bash
# Read-only static safety checks for repository-owned deployment workflows.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/otta-deploy-config.sh
. "$SCRIPT_DIR/otta-deploy-config.sh"

yml=".otta.yml"
requested_environment=""
while [ $# -gt 0 ]; do
  case "$1" in
    --otta-yml) yml="$2"; shift 2 ;;
    --environment) requested_environment="$2"; shift 2 ;;
    *) echo "usage: otta-deploy-readiness.sh [--otta-yml path] [--environment name]" >&2; exit 2 ;;
  esac
done

failures=0
pass() { echo "PASS $1 — $2"; }
warn() { echo "WARN $1 — $2"; }
fail() { echo "FAIL $1 — $2"; failures=$((failures + 1)); }

_workflow_has_push_trigger() {
  awk '
    function clean(value) {
      sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      return value
    }
    /^[[:space:]]*#/ { next }
    {
      line=$0
      if (line ~ /^["\047]?on["\047]?:/) {
        value=line; sub(/^["\047]?on["\047]?:[[:space:]]*/, "", value); value=clean(value)
        plain=value; gsub(/^"|"$/, "", plain); gsub(/^\047|\047$/, "", plain)
        if (plain == "push") found=1
        if (value ~ /^\[/) {
          gsub(/^\[|\]$/, "", value); count=split(value, items, ",")
          for (i=1; i<=count; i++) {
            item=clean(items[i]); gsub(/^"|"$/, "", item); gsub(/^\047|\047$/, "", item)
            if (item == "push") found=1
          }
        }
        in_on=(value == ""); next
      }
      if (in_on && line ~ /^[^[:space:]]/) in_on=0
      if (in_on && line ~ /^[[:space:]]{2,}["\047]?push["\047]?:/) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

_workflow_targets_environment() {
  local workflow_file="$1" wanted_environment="$2"
  awk -v wanted="$wanted_environment" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
      return value
    }
    function unquote(value) {
      value=trim(value); gsub(/^"|"$/, "", value); gsub(/^\047|\047$/, "", value)
      return value
    }
    function exact(value) { return unquote(value) == wanted }
    /^[[:space:]]*#/ { next }
    {
      line=$0; sub(/[[:space:]]+#.*$/, "", line)
      indent=match(line, /[^ ]/) - 1
      if (in_environment && indent <= environment_indent && line !~ /^[[:space:]]*$/) in_environment=0
      if (in_environment && line ~ /^[[:space:]]+["\047]?name["\047]?:/) {
        value=line; sub(/^[[:space:]]+["\047]?name["\047]?:[[:space:]]*/, "", value)
        if (exact(value)) found=1
      }
      if (line ~ /^[[:space:]]+["\047]?environment["\047]?:/) {
        environment_indent=indent
        value=line; sub(/^[[:space:]]+["\047]?environment["\047]?:[[:space:]]*/, "", value); value=trim(value)
        if (value == "") { in_environment=1; next }
        if (value ~ /^\{/) {
          gsub(/^\{|\}$/, "", value); count=split(value, fields, ",")
          for (i=1; i<=count; i++) {
            field=fields[i]; key=field; sub(/:.*/, "", key)
            field_value=field; sub(/^[^:]+:[[:space:]]*/, "", field_value)
            if (unquote(key) == "name" && exact(field_value)) found=1
          }
        } else if (exact(value)) found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$workflow_file"
}

[ -f "$yml" ] || { echo "N/A deploy workflow — no .otta.yml"; exit 0; }
environment="$(resolve_deploy_environment "$yml" "$requested_environment")" || exit $?
executor="$(deploy_config_value "$yml" "$environment" executor)"
[ "$executor" = github-workflow ] || { echo "N/A deploy workflow — executor=${executor:-none}"; exit 0; }

repo_root="$(cd "$(dirname "$yml")" && pwd)"
workflow="$(deploy_config_value "$yml" "$environment" workflow)"
sha_input="$(deploy_config_value "$yml" "$environment" sha_input)"
sha_input="${sha_input:-commit_sha}"
target="$(deploy_config_value "$yml" "$environment" target)"
target="${target:-$environment}"
shared_host="$(deploy_config_value "$yml" "$environment" shared_host)"

if [ -z "$workflow" ]; then
  fail 'configured workflow' "environment=$environment has no workflow"
  exit 1
fi
case "$workflow" in
  /*) workflow_path="$workflow" ;;
  .github/*) workflow_path="$repo_root/$workflow" ;;
  *) workflow_path="$repo_root/.github/workflows/$workflow" ;;
esac
[ -f "$workflow_path" ] || { fail 'configured workflow' "not found: $workflow_path"; exit 1; }
pass 'configured workflow' "$workflow_path"

if grep -Eq '^[[:space:]]+workflow_dispatch:[[:space:]]*($|#)' "$workflow_path"; then
  pass workflow_dispatch 'manual exact-SHA dispatch is declared'
else
  fail workflow_dispatch 'missing on.workflow_dispatch'
fi

if grep -Eq "^[[:space:]]{6,}${sha_input}:[[:space:]]*($|#)" "$workflow_path"; then
  pass 'SHA input' "$sha_input is declared"
else
  fail 'SHA input' "workflow_dispatch input $sha_input is missing"
fi

run_name="$(grep -E '^run-name:' "$workflow_path" | head -1 | sed 's/^run-name:[[:space:]]*//' || true)"
if printf '%s\n' "$run_name" | grep -Eq "(^|[^A-Za-z0-9])\\\$\\{\\{[[:space:]]*inputs\\.${sha_input}[[:space:]]*\\}\\}([^A-Za-z0-9]|$)"; then
  pass 'exact-SHA run-name' "inputs.$sha_input is a display-title marker"
else
  fail 'exact-SHA run-name' "run-name must contain standalone \${{ inputs.$sha_input }}"
fi
if printf '%s\n' "$run_name" | grep -Eq "(^|[^A-Za-z0-9])${environment}([^A-Za-z0-9]|$)"; then
  pass 'environment run-name' "$environment is a standalone display-title marker"
else
  fail 'environment run-name' "run-name must contain standalone $environment"
fi

if _workflow_has_push_trigger "$workflow_path"; then
  fail 'configured workflow trigger' 'selected deployment workflow must not have an ordinary push trigger'
else
  pass 'configured workflow trigger' 'selected deployment workflow dispatches explicitly only'
fi

group_line="$(grep -E '^[[:space:]]+group:' "$workflow_path" | head -1 || true)"
group_value="$(printf '%s\n' "$group_line" | sed 's/^[[:space:]]*group:[[:space:]]*//;s/[[:space:]]*#.*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')"
if [ -n "$group_value" ] && {
     printf '%s\n' "$group_value" | grep -Eqi "(^|[^A-Za-z0-9])${environment}([^A-Za-z0-9]|$)" ||
     printf '%s\n' "$group_value" | grep -Eqi "(^|[^A-Za-z0-9])${target}([^A-Za-z0-9]|$)" ||
     printf '%s\n' "$group_value" | grep -Eq '(^|[^A-Za-z0-9])\$\{\{[[:space:]]*inputs\.environment[[:space:]]*\}\}([^A-Za-z0-9]|$)';
   }; then
  pass 'per-environment concurrency' "group isolates $environment"
else
  fail 'per-environment concurrency' "concurrency.group must identify $environment"
fi
if grep -Eq '^[[:space:]]+cancel-in-progress:[[:space:]]+false([[:space:]]*#.*)?$' "$workflow_path"; then
  pass 'non-cancelling concurrency' 'active provider mutation is never cancelled'
else
  fail 'non-cancelling concurrency' 'cancel-in-progress must be false'
fi

if grep -Fq 'otta: same-sha-noop' "$workflow_path" &&
   grep -Fq "\${{ inputs.$sha_input }}" "$workflow_path" && grep -Eq 'exit[[:space:]]+0' "$workflow_path"; then
  pass 'same-SHA no-op' 'workflow declares and implements exact-SHA no-op'
else
  fail 'same-SHA no-op' 'missing otta: same-sha-noop marker, SHA comparison, or successful exit'
fi

if grep -Fq 'otta: health-sha-verify' "$workflow_path" &&
   grep -Eq 'curl|wget' "$workflow_path" && grep -Fq "\${{ inputs.$sha_input }}" "$workflow_path"; then
  pass 'runtime health verification' 'workflow verifies live exact SHA'
else
  fail 'runtime health verification' 'missing health verification marker, probe, or SHA comparison'
fi

competing=""
for candidate in "$repo_root/.github/workflows"/*.yml "$repo_root/.github/workflows"/*.yaml; do
  [ -f "$candidate" ] || continue
  [ "$candidate" = "$workflow_path" ] && continue
  if _workflow_has_push_trigger "$candidate" &&
     { _workflow_targets_environment "$candidate" "$environment" ||
       _workflow_targets_environment "$candidate" "$target"; }; then
    competing="$candidate"; break
  fi
done
if [ -n "$competing" ]; then
  fail 'competing production trigger' "$competing can mutate $environment on push"
else
  pass 'competing production trigger' "no push-triggered $environment workflow detected"
fi

warn 'preemptive supersession disabled' 'queued/running dispatch is not durable policy-eligibility proof; only a verified descendant can include older work'
if [ "$shared_host" = true ]; then
  warn 'shared host' 'repository-local concurrency is insufficient; use a single-capacity shared runner or external host semaphore'
else
  pass 'host isolation' 'no shared constrained host declared'
fi

[ "$failures" -eq 0 ]
