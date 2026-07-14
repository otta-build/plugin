#!/usr/bin/env bash
# otta-readiness.test.sh — AC4/AC7: score math 0/8, 8/8, 4/8 partial; read-only assertion
# Run: bash tests/otta-readiness.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-readiness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$SCRIPT" ] || fail "otta-readiness.sh not found at $SCRIPT"

# Helper: make a minimal stub gh that returns the given exit code and (optionally) output
make_gh_stub() {
  local bin="$1" exit_code="$2" output="${3:-}"
  mkdir -p "$bin"
  printf '#!/bin/sh\necho "%s"\nexit %s\n' "$output" "$exit_code" > "$bin/gh"
  chmod +x "$bin/gh"
}

make_curl_status_stub() {
  local bin="$1" state="$2" http_code="${3:-200}"
  mkdir -p "$bin"
  cat > "$bin/curl" <<SH
#!/usr/bin/env bash
printf '%s\\n${http_code}' '{"repo":"fake/repo","state":"${state}","repositoryAccess":true,"checksWrite":true}'
SH
  chmod +x "$bin/curl"
}

# =============================================================================
# 1. Score 0/8 — bare git repo, no dimensions satisfied
# =============================================================================
ZERO_REPO="$TMP/zero"
mkdir -p "$ZERO_REPO"
cd "$ZERO_REPO"
git init -q
git config user.email t@t.t
git config user.name t
echo base > f.txt; git add f.txt; git commit -qm base

# stub gh to fail (no branch protection detectable)
FAKE_BIN_ZERO="$TMP/bin-zero"
make_gh_stub "$FAKE_BIN_ZERO" 1 ""

OUTPUT="$(PATH="$FAKE_BIN_ZERO:$PATH" bash "$SCRIPT" 2>&1)" || true
echo "$OUTPUT" | grep -qE '0/8' \
  || fail "zero-repo: expected '0/8' in output, got:\n$OUTPUT"
echo "  ✓ 0/8 score correct"

# =============================================================================
# 2. Score 8/8 — all dimensions satisfied
# =============================================================================
ALL_REPO="$TMP/all"
mkdir -p "$ALL_REPO"
cd "$ALL_REPO"
git init -q
git config user.email t@t.t
git config user.name t
echo base > f.txt; git add f.txt; git commit -qm base
git remote add origin https://github.com/fake/repo.git

# dim 8: .otta.yml exists + dim 1: base/staging configured
cat > .otta.yml <<'YAML'
base: main
staging: staging
YAML

# dim 2: CI workflow
mkdir -p .github/workflows
echo 'name: ci' > .github/workflows/ci.yml

# dim 4: gate hook (husky pre-push referencing otta)
mkdir -p .husky
printf '#!/bin/sh\nbash scripts/otta-gate.sh\n' > .husky/pre-push
chmod +x .husky/pre-push

# dim 5: Pulse connected
mkdir -p .otta
echo 'OTTA_PULSE_TOKEN=fake' > .otta/pulse.env

# dim 6: sandbox configured
mkdir -p .claude
echo '{"sandbox": {"enabled": true}}' > .claude/settings.json

# dim 7: telemetry on
echo '{"env": {"OTEL_EXPORTER_OTLP_ENDPOINT": "https://pulse.otta.build"}}' > .claude/settings.local.json

# dim 3: branch protection — stub gh to succeed with a fake repo slug
FAKE_BIN_ALL="$TMP/bin-all"
mkdir -p "$FAKE_BIN_ALL"
cat > "$FAKE_BIN_ALL/gh" <<'SH'
#!/bin/sh
case "$*" in
  *nameWithOwner*) echo "fake/repo" ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$FAKE_BIN_ALL/gh"
make_curl_status_stub "$FAKE_BIN_ALL" ready

OUTPUT="$(PATH="$FAKE_BIN_ALL:$PATH" bash "$SCRIPT" 2>&1)" || true
echo "$OUTPUT" | grep -qE '8/8' \
  || fail "all-repo: expected '8/8' in output, got:\n$OUTPUT"
echo "  ✓ 8/8 score correct"

mkdir -p "$ALL_REPO/packages/example"
OUTPUT="$(cd "$ALL_REPO/packages/example" && PATH="$FAKE_BIN_ALL:$PATH" bash "$SCRIPT" 2>&1)" || true
echo "$OUTPUT" | grep -qE '8/8' \
  || fail "subdirectory: expected root configuration to remain 8/8, got:\n$OUTPUT"
echo "$OUTPUT" | grep -q 'Pulse connected (repository access + checks:write verified)' \
  || fail "subdirectory: root pulse.env was not server-verified: $OUTPUT"
echo "  ✓ repository root Pulse configuration works from a subdirectory"

# =============================================================================
# 3. Score 3/8 — partial: dims 1, 2, 8 only; pulse.env is unverified
# =============================================================================
PARTIAL_REPO="$TMP/partial"
mkdir -p "$PARTIAL_REPO"
cd "$PARTIAL_REPO"
git init -q
git config user.email t@t.t
git config user.name t
echo base > f.txt; git add f.txt; git commit -qm base

# dim 8 + dim 1: .otta.yml with base + staging
cat > .otta.yml <<'YAML'
base: main
staging: staging
YAML

# dim 2: CI workflow
mkdir -p .github/workflows
echo 'name: ci' > .github/workflows/ci.yml

# dim 5: Pulse connected
mkdir -p .otta
echo 'OTTA_PULSE_TOKEN=fake' > .otta/pulse.env

# no dim 3 (gh fails), no dim 4, no dim 6, no dim 7
FAKE_BIN_P="$TMP/bin-partial"
make_gh_stub "$FAKE_BIN_P" 1 ""
make_curl_status_stub "$FAKE_BIN_P" not_installed

OUTPUT="$(PATH="$FAKE_BIN_P:$PATH" bash "$SCRIPT" 2>&1)" || true
echo "$OUTPUT" | grep -qE '3/8' \
  || fail "partial-repo: expected '3/8' in output, got:\n$OUTPUT"
echo "  ✓ 3/8 score correct (pulse.env alone is not connected)"

# =============================================================================
# 4. Read-only — running the script leaves no new files in the repo
# =============================================================================
cd "$PARTIAL_REPO"
FILES_BEFORE="$(find . -not -path './.git/*' | sort)"
PATH="$FAKE_BIN_P:$PATH" bash "$SCRIPT" > /dev/null 2>&1 || true
FILES_AFTER="$(find . -not -path './.git/*' | sort)"
[ "$FILES_BEFORE" = "$FILES_AFTER" ] \
  || fail "readiness script is NOT read-only — file set changed:\n$(diff <(echo "$FILES_BEFORE") <(echo "$FILES_AFTER") || true)"
echo "  ✓ read-only verified"

# =============================================================================
# 5. Output has a per-dimension ✓/✗ list (at least one ✓ and one ✗ in partial)
# =============================================================================
cd "$PARTIAL_REPO"
OUTPUT="$(PATH="$FAKE_BIN_P:$PATH" bash "$SCRIPT" 2>&1)" || true
echo "$OUTPUT" | grep -q "✓" || fail "partial output has no ✓ lines"
echo "$OUTPUT" | grep -q "✗" || fail "partial output has no ✗ lines"
echo "  ✓ per-dimension ✓/✗ list present"

# Hosted status, not pulse.env existence, is connection truth.
for state in not_installed permission_approval_required github_unavailable; do
  STATUS_REPO="$TMP/status-$state"
  cp -R "$PARTIAL_REPO" "$STATUS_REPO"
  STATUS_BIN="$TMP/bin-$state"
  make_gh_stub "$STATUS_BIN" 0 "fake/repo"
  code=200
  [ "$state" = github_unavailable ] && code=502
  make_curl_status_stub "$STATUS_BIN" "$state" "$code"
  OUTPUT="$(cd "$STATUS_REPO" && PATH="$STATUS_BIN:$PATH" bash "$SCRIPT" 2>&1)" || true
  echo "$OUTPUT" | grep -Eq 'Pulse not connected|Pulse verification unavailable' \
    || fail "$state: readiness lacks truthful hosted status: $OUTPUT"
  ! echo "$OUTPUT" | grep -q 'Pulse connected (.otta/pulse.env present)' \
    || fail "$state: file existence was falsely reported connected"
done
echo "  ✓ hosted Pulse status overrides pulse.env file existence"

# Deploy readiness is invoked only for configured GitHub Workflow executors.
OUTPUT="$(cd "$ZERO_REPO" && PATH="$FAKE_BIN_ZERO:$PATH" bash "$SCRIPT" 2>&1)" || true
echo "$OUTPUT" | grep -Fq 'Deploy workflow safety: not applicable' \
  || fail "no-runtime repo should report deploy safety not applicable: $OUTPUT"
echo "  ✓ no-runtime repository reports deploy safety not applicable"

DEPLOY_REPO="$TMP/deploy-unsafe"
mkdir -p "$DEPLOY_REPO/.github/workflows"
cd "$DEPLOY_REPO"
git init -q
git config user.email t@t.t
git config user.name t
echo base > f; git add f; git commit -qm base
cat > .otta.yml <<'YAML'
deploy:
  auto: human-approve
  target: production
  executor: github-workflow
  workflow: deploy.yml
  sha_input: sha
YAML
echo 'name: unsafe' > .github/workflows/deploy.yml
set +e
OUTPUT="$(PATH="$FAKE_BIN_ZERO:$PATH" bash "$SCRIPT" 2>&1)"; DEPLOY_RC=$?
set -e
[ "$DEPLOY_RC" -ne 0 ] || fail 'unsafe configured workflow should make general readiness fail'
echo "$OUTPUT" | grep -Fq 'FAIL workflow_dispatch' \
  || fail "general readiness did not invoke deploy validation: $OUTPUT"
echo "  ✓ configured unsafe workflow fails general readiness"

NAMED_REPO="$TMP/deploy-named"
mkdir -p "$NAMED_REPO/.github/workflows"
cd "$NAMED_REPO"
git init -q
git config user.email t@t.t
git config user.name t
echo base > f; git add f; git commit -qm base
cat > .otta.yml <<'YAML'
deploy:
  default: production
  environments:
    staging:
      target: staging
      executor: github-workflow
      workflow: deploy-staging.yml
      sha_input: sha
      health_url: https://staging.example.test/health
      health_commit_field: commit
    production:
      target: production
      executor: github-workflow
      workflow: deploy-production.yml
      sha_input: sha
      health_url: https://app.example.test/health
      health_commit_field: commit
YAML
cat > .github/workflows/deploy-production.yml <<'YAML'
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
      - name: Noop
        # otta: same-sha-noop
        run: test "$(curl -fsS /health | jq -r .commit)" != "${{ inputs.sha }}" || exit 0
      - name: Verify
        # otta: health-sha-verify
        run: test "$(curl -fsS /health | jq -r .commit)" = "${{ inputs.sha }}"
YAML
echo 'name: unsafe staging' > .github/workflows/deploy-staging.yml
set +e
OUTPUT="$(PATH="$FAKE_BIN_ZERO:$PATH" bash "$SCRIPT" 2>&1)"; NAMED_RC=$?
set -e
[ "$NAMED_RC" -ne 0 ] || fail 'unsafe non-default staging profile should make general readiness fail'
echo "$OUTPUT" | grep -Fq 'environment=staging' \
  || fail "general readiness did not validate the non-default staging environment: $OUTPUT"
echo "$OUTPUT" | grep -Fq 'FAIL workflow_dispatch' \
  || fail "non-default staging workflow failure missing: $OUTPUT"
echo "  ✓ every named deployment environment is validated"

echo "✓ otta-readiness: all checks passed (0/8, 8/8, 3/8, read-only, hosted status, per-dim list)"
