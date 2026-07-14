#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$HERE/../scripts/otta-deploy-config.sh"
VERIFY="$HERE/../scripts/otta-deploy-verify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }
check() { [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"; echo "  ✓ $1"; }

[ -f "$RESOLVER" ] || fail "resolver missing: $RESOLVER"
# shellcheck disable=SC1090
. "$RESOLVER"
# shellcheck disable=SC1090
. "$VERIFY"

NAMED="$TMP/named.yml"
cat > "$NAMED" <<'YAML'
deploy:
  default: production
  environments:
    staging:
      auto: merge-and-deploy
      target: staging
      executor: github-workflow
      workflow: deploy-staging.yml
      ref: staging
      sha_input: sha
      verify: health-sha
      health_url: https://staging.example.test/health
      health_commit_field: commit
    production:
      auto: human-approve
      target: production
      executor: github-workflow
      workflow: deploy-production.yml
      ref: main
      sha_input: sha
      verify: health-sha
      health_url: https://app.example.test/health
      health_commit_field: commit
YAML

check 'named environments detected' true "$(deploy_has_named_environments "$NAMED")"
check 'default environment parsed' production "$(parse_deploy_default_environment "$NAMED")"
check 'empty request resolves default' production "$(resolve_deploy_environment "$NAMED" '')"
check 'explicit staging resolves staging' staging "$(resolve_deploy_environment "$NAMED" staging)"
check 'staging workflow read' deploy-staging.yml "$(deploy_config_value "$NAMED" staging workflow)"
check 'production auto read' human-approve "$(deploy_config_value "$NAMED" production auto)"
check 'deploy parser selects staging workflow' deploy-staging.yml "$(parse_deploy_workflow "$NAMED" staging)"
check 'deploy parser selects default auto' human-approve "$(parse_deploy_auto "$NAMED" production)"
if resolve_deploy_environment "$NAMED" preview >/dev/null 2>&1; then fail 'unknown environment must fail'; fi

OUTSIDE="$TMP/outside.yml"
cp "$NAMED" "$OUTSIDE"
cat >> "$OUTSIDE" <<'YAML'
other:
  nested:
    preview:
      workflow: evil.yml
YAML
if resolve_deploy_environment "$OUTSIDE" preview >/dev/null 2>&1; then fail 'environment names outside deploy.environments must be ignored'; fi
echo '  ✓ environment lookup stays inside deploy.environments'

LEGACY="$TMP/legacy.yml"
cat > "$LEGACY" <<'YAML'
deploy:
  auto: merge-on-green
  target: production
  executor: github-workflow
  workflow: deploy.yml
YAML
check 'flat config has no named environments' false "$(deploy_has_named_environments "$LEGACY")"
check 'flat config resolves legacy' legacy "$(resolve_deploy_environment "$LEGACY" '')"
check 'legacy value preserved' deploy.yml "$(deploy_config_value "$LEGACY" legacy workflow)"

set +e
CLI_OUT="$({
  git() { [ "$1 $2 $3" = 'remote get-url origin' ] && echo 'git@github.com:acme/widget.git'; }
  gh() {
    if [ "$1 $2" = 'pr view' ]; then
      printf '%s\n' '{"state":"OPEN","headRefOid":"abc123","mergeCommit":null}'
    fi
  }
  _run 7 --otta-yml "$NAMED" --environment production
} 2>&1)"
CLI_RC=$?
set -e
[ "$CLI_RC" -ne 0 ] || fail 'human-approved production fixture should pause'
printf '%s\n' "$CLI_OUT" | grep -Fq 'deploy policy: environment=production' || fail '--environment was not threaded into the policy banner'
echo '  ✓ command selects and reports the requested environment'

for invalid in tabs duplicate missing-default nested-value; do
  file="$TMP/$invalid.yml"
  case "$invalid" in
    tabs) printf 'deploy:\n\tdefault: production\n  environments:\n' > "$file" ;;
    duplicate) cat > "$file" <<'YAML'
deploy:
  default: production
  environments:
    production:
      target: production
    production:
      target: production
YAML
      ;;
    missing-default) cat > "$file" <<'YAML'
deploy:
  environments:
    production:
      target: production
YAML
      ;;
    nested-value) cat > "$file" <<'YAML'
deploy:
  default: production
  environments:
    production:
      workflow:
        nested: invalid
YAML
      ;;
  esac
  if resolve_deploy_environment "$file" '' >/dev/null 2>&1; then fail "$invalid config must fail closed"; fi
  echo "  ✓ $invalid config fails closed"
done

echo '✓ named deployment environment resolver'
