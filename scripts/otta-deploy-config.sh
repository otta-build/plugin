#!/usr/bin/env bash
# Strict reader for Otta's flat or one-level named deployment configuration.

_deploy_config_shape() {
  local yml="$1"
  [ -f "$yml" ] || { echo legacy; return 0; }
  awk '
    function fail(message) { print "deploy config: " message > "/dev/stderr"; bad=1; exit 2 }
    /\t/ { fail("tabs are not supported") }
    /^[^ #]/ {
      if ($0 ~ /^deploy:[[:space:]]*(#.*)?$/) { in_deploy=1; next }
      if (in_deploy) in_deploy=0
    }
    !in_deploy || /^[[:space:]]*(#|$)/ { next }
    /^  environments:[[:space:]]*(#.*)?$/ { named=1; next }
    named && /^    [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      name=$0; sub(/^    /, "", name); sub(/:.*/, "", name)
      if (seen[name]++) fail("duplicate environment " name)
      env_count++; current=name; next
    }
    named && /^      [A-Za-z0-9_]+:/ {
      line=$0; sub(/^      /, "", line); key=line; sub(/:.*/, "", key)
      value=line; sub(/^[^:]+:[[:space:]]*/, "", value); sub(/[[:space:]]*#.*$/, "", value)
      if (key ~ /^(auto|target|project|executor|workflow|ref|sha_input|provider|verify|health_url|health_commit_field|allow_production|shared_host)$/ &&
          (value == "" || value ~ /^[\[{|>]/)) fail("known key " key " must have a scalar value")
      next
    }
    named && /^        / { fail("nested environment values are not supported") }
    in_deploy && /^  default:/ {
      default_name=$0; sub(/^  default:[[:space:]]*/, "", default_name); sub(/[[:space:]]*#.*$/, "", default_name)
      gsub(/^"|"$/, "", default_name); gsub(/^\047|\047$/, "", default_name); next
    }
    END {
      if (bad) exit 2
      if (named) {
        if (default_name == "") { print "deploy config: named environments require deploy.default" > "/dev/stderr"; exit 2 }
        if (!seen[default_name]) { print "deploy config: default environment is not defined: " default_name > "/dev/stderr"; exit 2 }
        print "named"
      } else print "legacy"
    }
  ' "$yml"
}

deploy_has_named_environments() {
  local shape
  shape="$(_deploy_config_shape "$1")" || return $?
  [ "$shape" = named ] && echo true || echo false
}

list_deploy_environments() {
  local yml="$1" shape
  shape="$(_deploy_config_shape "$yml")" || return $?
  [ "$shape" = named ] || { echo legacy; return 0; }
  awk '
    /^deploy:[[:space:]]*(#.*)?$/ { in_deploy=1; next }
    /^[^ #]/ { if (in_deploy) { in_deploy=0; in_environments=0 } }
    in_deploy && /^  environments:[[:space:]]*(#.*)?$/ { in_environments=1; next }
    in_deploy && in_environments && /^  [^ ]/ { in_environments=0 }
    in_environments && /^    [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      name=$0; sub(/^    /, "", name); sub(/:.*/, "", name); print name
    }
  ' "$yml"
}

parse_deploy_default_environment() {
  local yml="$1" shape
  shape="$(_deploy_config_shape "$yml")" || return $?
  [ "$shape" = named ] || { echo legacy; return 0; }
  awk '
    /^deploy:[[:space:]]*(#.*)?$/ { in_deploy=1; next }
    /^[^ #]/ { if (in_deploy) exit }
    in_deploy && /^  default:/ {
      sub(/^  default:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      gsub(/^"|"$/, ""); gsub(/^\047|\047$/, ""); print; exit
    }
  ' "$yml"
}

resolve_deploy_environment() {
  local yml="$1" requested="${2:-}" shape selected
  shape="$(_deploy_config_shape "$yml")" || return $?
  if [ "$shape" = legacy ]; then
    [ -z "$requested" ] || [ "$requested" = legacy ] || {
      echo "deploy config: legacy config has no environment named $requested" >&2; return 2;
    }
    echo legacy; return 0
  fi
  selected="$requested"
  [ -n "$selected" ] || selected="$(parse_deploy_default_environment "$yml")" || return $?
  awk -v wanted="$selected" '
    /^deploy:[[:space:]]*(#.*)?$/ { in_deploy=1; next }
    /^[^ #]/ { if (in_deploy) { in_deploy=0; in_environments=0 } }
    in_deploy && /^  environments:[[:space:]]*(#.*)?$/ { in_environments=1; next }
    in_deploy && in_environments && /^  [^ ]/ { in_environments=0 }
    in_environments && /^    [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      name=$0; sub(/^    /, "", name); sub(/:.*/, "", name); if (name == wanted) found=1
    }
    END { exit(found ? 0 : 1) }
  ' "$yml" || { echo "deploy config: unknown environment $selected" >&2; return 2; }
  echo "$selected"
}

deploy_config_value() {
  local yml="$1" environment="$2" key="$3" shape
  shape="$(_deploy_config_shape "$yml")" || return $?
  if [ "$shape" = legacy ]; then
    [ "$environment" = legacy ] || return 2
    awk -v wanted="$key" '
      /^deploy:[[:space:]]*(#.*)?$/ { in_deploy=1; next }
      /^[^ #]/ { if (in_deploy) exit }
      in_deploy && $0 ~ "^  " wanted ":[[:space:]]*" {
        sub("^  " wanted ":[[:space:]]*", ""); sub(/[[:space:]]*#.*$/, "");
        gsub(/^"|"$/, ""); gsub(/^\047|\047$/, ""); print; exit
      }
    ' "$yml"
    return
  fi
  resolve_deploy_environment "$yml" "$environment" >/dev/null || return $?
  awk -v env="$environment" -v wanted="$key" '
    /^deploy:[[:space:]]*(#.*)?$/ { in_deploy=1; next }
    /^[^ #]/ { if (in_deploy) { in_deploy=0; in_environments=0; in_env=0 } }
    in_deploy && /^  environments:[[:space:]]*(#.*)?$/ { in_environments=1; next }
    in_deploy && in_environments && /^  [^ ]/ { in_environments=0; in_env=0 }
    in_environments && /^    [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
      name=$0; sub(/^    /, "", name); sub(/:.*/, "", name); in_env=(name == env); next
    }
    in_env && $0 ~ "^      " wanted ":[[:space:]]*" {
      sub("^      " wanted ":[[:space:]]*", ""); sub(/[[:space:]]*#.*$/, "");
      gsub(/^"|"$/, ""); gsub(/^\047|\047$/, ""); print; exit
    }
  ' "$yml"
}
