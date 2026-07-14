#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-deploy-readiness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

make_repo() {
  repo="$1"
  mkdir -p "$repo/.github/workflows"
  cat > "$repo/.otta.yml" <<'YAML'
deploy:
  default: production
  environments:
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
  cat > "$repo/.github/workflows/deploy-production.yml" <<'YAML'
name: deploy production
run-name: deploy production ${{ inputs.sha }}
on:
  workflow_dispatch:
    inputs:
      sha:
        required: true
concurrency:
  group: deploy-production
  cancel-in-progress: false
jobs:
  deploy:
    environment: production
    steps:
      - name: No-op when exact SHA is live
        # otta: same-sha-noop
        run: current="$(curl -fsS https://app.example.test/health | jq -r .commit)"; [ "$current" != "${{ inputs.sha }}" ] || exit 0
      - name: Deploy requested SHA
        run: ./deploy "${{ inputs.sha }}"
      - name: Verify exact live SHA
        # otta: health-sha-verify
        run: test "$(curl -fsS https://app.example.test/health | jq -r .commit)" = "${{ inputs.sha }}"
YAML
}

[ -f "$SCRIPT" ] || fail "deploy readiness script missing: $SCRIPT"

VALID="$TMP/valid"
make_repo "$VALID"
output="$(bash "$SCRIPT" --otta-yml "$VALID/.otta.yml" --environment production)" || fail "valid workflow was rejected: $output"
printf '%s\n' "$output" | grep -Fq 'PASS workflow_dispatch' || fail 'valid dispatch not reported'
printf '%s\n' "$output" | grep -Fq 'WARN preemptive supersession disabled' || fail 'safe default warning missing'
echo '  ✓ valid repository-owned workflow passes with safe latest-wins warning'

assert_failure() {
  name="$1" pattern="$2"; shift 2
  repo="$TMP/$name"
  make_repo "$repo"
  "$@" "$repo/.github/workflows/deploy-production.yml"
  set +e
  output="$(bash "$SCRIPT" --otta-yml "$repo/.otta.yml" --environment production 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$name should fail"
  printf '%s\n' "$output" | grep -Fq "$pattern" || fail "$name missing expected failure [$pattern]: $output"
  echo "  ✓ $name fails closed"
}

remove_dispatch() { sed -i.bak '/workflow_dispatch:/d' "$1"; rm -f "$1.bak"; }
remove_sha_input() { sed -i.bak '/      sha:/d' "$1"; rm -f "$1.bak"; }
remove_run_name() { sed -i.bak '/^run-name:/d' "$1"; rm -f "$1.bak"; }
embed_sha_marker() { sed -i.bak 's/${{ inputs.sha }}/${{ inputs.sha }}suffix/' "$1"; rm -f "$1.bak"; }
remove_environment_marker() { sed -i.bak 's/run-name: deploy production/run-name: deploy/' "$1"; rm -f "$1.bak"; }
add_push_trigger() { awk '{ print; if ($0 == "on:") print "  push:" }' "$1" > "$1.tmp"; mv "$1.tmp" "$1"; }
enable_cancellation() { sed -i.bak 's/cancel-in-progress: false/cancel-in-progress: true/' "$1"; rm -f "$1.bak"; }
wrong_concurrency() { sed -i.bak 's/group: deploy-production/group: deploy-global/' "$1"; rm -f "$1.bak"; }
remove_noop() { sed -i.bak '/otta: same-sha-noop/d' "$1"; rm -f "$1.bak"; }
remove_health() { sed -i.bak '/otta: health-sha-verify/d' "$1"; rm -f "$1.bak"; }

assert_failure missing-dispatch 'FAIL workflow_dispatch' remove_dispatch
assert_failure missing-sha-input 'FAIL SHA input' remove_sha_input
assert_failure missing-run-name 'FAIL exact-SHA run-name' remove_run_name
assert_failure embedded-sha-run-name 'FAIL exact-SHA run-name' embed_sha_marker
assert_failure missing-environment-run-name 'FAIL environment run-name' remove_environment_marker
assert_failure configured-workflow-push-trigger 'FAIL configured workflow trigger' add_push_trigger
assert_failure cancellation-enabled 'FAIL non-cancelling concurrency' enable_cancellation
assert_failure environment-independent-concurrency 'FAIL per-environment concurrency' wrong_concurrency
assert_failure missing-same-sha-noop 'FAIL same-SHA no-op' remove_noop
assert_failure missing-health-verification 'FAIL runtime health verification' remove_health

COMPETING="$TMP/competing"
make_repo "$COMPETING"
cat > "$COMPETING/.github/workflows/legacy-deploy.yml" <<'YAML'
name: legacy production deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    environment: production
    steps:
      - run: ./deploy
YAML
set +e
output="$(bash "$SCRIPT" --otta-yml "$COMPETING/.otta.yml" --environment production 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'competing push deploy should fail'
printf '%s\n' "$output" | grep -Fq 'FAIL competing production trigger' || fail "competing trigger failure missing: $output"
echo '  ✓ competing push-triggered production workflow fails closed'

for trigger_form in scalar sequence quoted block; do
  TRIGGER_REPO="$TMP/competing-$trigger_form"
  make_repo "$TRIGGER_REPO"
  case "$trigger_form" in
    scalar) trigger='on: push' ;;
    sequence) trigger='on: [push]' ;;
    quoted) trigger='"on": push' ;;
    block) trigger=$'on:\n  push:' ;;
  esac
  printf 'name: competing %s\n%s\njobs:\n  deploy:\n    environment: production\n    steps:\n      - run: ./deploy\n' \
    "$trigger_form" "$trigger" > "$TRIGGER_REPO/.github/workflows/competing.yml"
  set +e
  output="$(bash "$SCRIPT" --otta-yml "$TRIGGER_REPO/.otta.yml" --environment production 2>&1)"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$trigger_form push trigger should be detected"
  printf '%s\n' "$output" | grep -Fq 'FAIL competing production trigger' \
    || fail "$trigger_form push trigger lacked competing failure: $output"
  echo "  ✓ competing $trigger_form push trigger detected"
done

SAFE_TRIGGER="$TMP/non-push-triggers"
make_repo "$SAFE_TRIGGER"
cat > "$SAFE_TRIGGER/.github/workflows/pr-only.yml" <<'YAML'
name: PR-only production checks
# on: push is documentation, not a trigger
on: pull_request
jobs:
  check:
    environment: production
    steps:
      - run: ./check-only
YAML
output="$(bash "$SCRIPT" --otta-yml "$SAFE_TRIGGER/.otta.yml" --environment production)" \
  || fail "comments and pull_request must not be false positives: $output"
printf '%s\n' "$output" | grep -Fq 'PASS competing production trigger' \
  || fail "safe pull_request workflow did not pass competing-trigger check: $output"
echo '  ✓ comments and pull_request do not trigger false positives'

SHARED="$TMP/shared"
make_repo "$SHARED"
awk '{ print; if ($0 == "      target: production") print "      shared_host: true" }' \
  "$SHARED/.otta.yml" > "$SHARED/.otta.yml.tmp"
mv "$SHARED/.otta.yml.tmp" "$SHARED/.otta.yml"
output="$(bash "$SCRIPT" --otta-yml "$SHARED/.otta.yml" --environment production)" || fail 'shared host warning should not fail an otherwise valid workflow'
printf '%s\n' "$output" | grep -Fq 'WARN shared host' || fail 'shared host warning missing'
echo '  ✓ shared constrained host warns without installing a broker'

echo '✓ deploy workflow readiness validation'
