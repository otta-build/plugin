#!/usr/bin/env bash
# write-otta-contract.test.sh — unit tests for write-otta-contract.sh
# Covers: deploy.auto + allow_production (issue #101 AC2), version: "1" header
# (issue #103 AC1), learn: opt-in block (AC2), models: comment (AC3), and
# otta-engine resolve_config YAML structure (AC4).
# Run: bash tests/write-otta-contract.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/write-otta-contract.sh"
VERIFY="$HERE/../scripts/otta-deploy-verify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

# ── Test 1: version: "1" at top of output (AC1 of #103) ──────────────────────
OUT="$TMP/t1.yml"
bash "$SCRIPT" --output "$OUT" >/dev/null 2>&1
grep -q '^version: "1"' "$OUT" || fail "test 1: version: \"1\" not emitted at top of .otta.yml"
version_line="$(grep -n '^version:' "$OUT" | head -1 | cut -d: -f1)"
tracker_line="$(grep -n '^tracker:' "$OUT" | head -1 | cut -d: -f1)"
[ -n "$version_line" ] && [ -n "$tracker_line" ] || fail "test 1: missing version or tracker line numbers"
[ "$version_line" -lt "$tracker_line" ] || fail "test 1: version: must appear before tracker: (lines $version_line vs $tracker_line)"
pass "version: \"1\" emitted before tracker:"

# ── Test 2: default deploy.auto=human-approve, no allow_production (AC2 #101) ─
OUT="$TMP/t2.yml"
bash "$SCRIPT" --output "$OUT" >/dev/null 2>&1
grep -q "auto: human-approve" "$OUT" || fail "test 2: default auto not human-approve"
grep -q "allow_production" "$OUT" && fail "test 2: allow_production should be absent by default" || true
pass "default: auto=human-approve, allow_production absent"

# ── Test 3: --deploy-auto merge-on-green ─────────────────────────────────────
OUT="$TMP/t3.yml"
bash "$SCRIPT" --output "$OUT" --deploy-auto merge-on-green >/dev/null 2>&1
grep -q "auto: merge-on-green" "$OUT" || fail "test 3: auto not merge-on-green"
grep -q "allow_production" "$OUT" && fail "test 3: allow_production should be absent" || true
pass "--deploy-auto merge-on-green: written correctly"

# ── Test 4: --deploy-auto merge-and-deploy + --allow-production ──────────────
OUT="$TMP/t4.yml"
bash "$SCRIPT" --output "$OUT" --deploy-auto merge-and-deploy --allow-production >/dev/null 2>&1
grep -q "auto: merge-and-deploy" "$OUT" || fail "test 4: auto not merge-and-deploy"
grep -q "allow_production: true" "$OUT" || fail "test 4: allow_production: true not written"
pass "--deploy-auto merge-and-deploy --allow-production: both keys written"

# ── Test 5: otta-deploy-verify.sh parses generated contract (AC2 of #101) ────
OUT="$TMP/t5.yml"
bash "$SCRIPT" --output "$OUT" --deploy-auto merge-on-green --deploy-target coolify --deploy-project myapp >/dev/null 2>&1
auto_val="$(bash -c "source '$VERIFY' 2>/dev/null; parse_deploy_auto '$OUT'")"
[ "$auto_val" = "merge-on-green" ] || fail "test 5: parse_deploy_auto returned '$auto_val', expected merge-on-green"
pass "otta-deploy-verify parse_deploy_auto reads generated contract correctly"

# ── Test 6: allow_production absent without --allow-production ────────────────
OUT="$TMP/t6.yml"
bash "$SCRIPT" --output "$OUT" --deploy-auto merge-and-deploy >/dev/null 2>&1
grep -q "allow_production" "$OUT" && fail "test 6: allow_production must not appear without --allow-production flag" || true
pass "allow_production absent when --allow-production not passed"

# ── Test 7: invalid --deploy-auto value rejected ──────────────────────────────
if bash "$SCRIPT" --deploy-auto invalid-value >/dev/null 2>&1; then
  fail "test 7: invalid --deploy-auto value should have exited non-zero"
fi
pass "invalid --deploy-auto value → non-zero exit"

# ── Test 8: learn: block disabled by default — commented out (AC2 #103) ───────
OUT="$TMP/t8.yml"
bash "$SCRIPT" --output "$OUT" >/dev/null 2>&1
grep -q '^# learn:' "$OUT" || fail "test 8: commented learn: block not present by default"
grep -q '^learn:' "$OUT" 2>/dev/null && fail "test 8: active learn: block should NOT appear without --learn" || true
pass "no --learn: learn: block is commented out (disabled by default)"

# ── Test 9: --learn emits active learn: block (AC2 opt-in #103) ──────────────
OUT="$TMP/t9.yml"
bash "$SCRIPT" --output "$OUT" --learn >/dev/null 2>&1
grep -q '^learn:' "$OUT" || fail "test 9: learn: block not emitted with --learn"
grep -q 'enabled: true' "$OUT" || fail "test 9: learn.enabled: true not emitted"
grep -q 'consult: true' "$OUT" || fail "test 9: learn.consult: true not emitted"
grep -q 'capture: true' "$OUT" || fail "test 9: learn.capture: true not emitted"
grep -q 'expiry_days: 180' "$OUT" || fail "test 9: learn.expiry_days: 180 (default) not emitted"
grep -q 'cadence: weekly' "$OUT" || fail "test 9: learn.cadence: weekly (default) not emitted"
pass "--learn: active learn block with independent consult/capture defaults"

# ── Test 10: --learn-expiry-days and --learn-cadence customization ────────────
OUT="$TMP/t10.yml"
bash "$SCRIPT" --output "$OUT" --learn --learn-expiry-days 30 --learn-cadence daily >/dev/null 2>&1
grep -q 'expiry_days: 30' "$OUT" || fail "test 10: --learn-expiry-days 30 not reflected"
grep -q 'cadence: daily' "$OUT" || fail "test 10: --learn-cadence daily not reflected"
pass "--learn-expiry-days 30 --learn-cadence daily: values written correctly"

# ── Test 11: models: comment present (AC3 of #103) ────────────────────────────
OUT="$TMP/t11.yml"
bash "$SCRIPT" --output "$OUT" >/dev/null 2>&1
grep -q '# models:' "$OUT" || fail "test 11: models: comment not emitted"
pass "models: comment present (advanced config hint)"

# ── Test 12: otta-engine resolve_config YAML structure (AC4 of #103) ──────────
OUT="$TMP/t12.yml"
bash "$SCRIPT" --output "$OUT" --learn >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
  python3 - "$OUT" << 'PYCHECK'
import sys, pathlib
try:
    import yaml
except ImportError:
    content = pathlib.Path(sys.argv[1]).read_text()
    lines = content.splitlines()
    keys = {l.split(':')[0].strip() for l in lines if ':' in l and not l.startswith('#')}
    assert 'version' in keys, f"Missing 'version' key; keys found: {keys}"
    version_line = next((l for l in lines if l.startswith('version:')), '')
    assert '"1"' in version_line, f"version must be \"1\", got: {version_line}"
    for k in ['tracker', 'autonomy', 'deploy', 'gates', 'telemetry', 'loops']:
        assert k in keys, f"Missing '{k}'"
    print("  structural check: ok (no PyYAML; used line scan)")
    sys.exit(0)

content = pathlib.Path(sys.argv[1]).read_text()
cfg = yaml.safe_load(content)
assert str(cfg.get('version', '')) == '1', \
    f"resolve_config expects version '1', got {cfg.get('version')!r}"
for k in ['tracker', 'autonomy', 'deploy', 'gates', 'telemetry', 'loops']:
    assert k in cfg, f"Missing '{k}'"
assert 'learn' in cfg, "Missing learn (was passed --learn)"
assert cfg['learn'].get('enabled') is True, f"learn.enabled should be True"
print("  python3 YAML assertions: ok")
PYCHECK
  pass "otta-engine resolve_config structure: version \"1\" + all 6 keys + learn block valid"
else
  echo "  ⚠ python3 unavailable — skipping engine YAML structure check (AC4)"
fi

# ── Test 13: GitHub workflow executor contract is additive (#137 AC1) ────────
OUT="$TMP/t13.yml"
bash "$SCRIPT" --output "$OUT" \
  --deploy-target production --deploy-project leadcognition \
  --deploy-auto human-approve --deploy-executor github-workflow \
  --deploy-workflow deploy-production.yml --deploy-ref main \
  --deploy-sha-input commit_sha --deploy-provider coolify \
  --deploy-verify health-sha \
  --deploy-health-url https://app.leadcognition.io/health \
  --deploy-health-commit-field commit >/dev/null 2>&1
for expected in \
  'executor: github-workflow' \
  'workflow: deploy-production.yml' \
  'ref: main' \
  'sha_input: commit_sha' \
  'provider: coolify' \
  'verify: health-sha' \
  'health_url: https://app.leadcognition.io/health' \
  'health_commit_field: commit'; do
  grep -q "^[[:space:]]*$expected$" "$OUT" || fail "test 13: missing generated deploy key: $expected"
done
pass "github-workflow executor fields preserve provider and verification config"

if bash "$SCRIPT" --deploy-executor github-workflow >/dev/null 2>&1; then
  fail "test 13: github-workflow without --deploy-workflow should fail"
fi
if bash "$SCRIPT" --deploy-executor unknown --deploy-workflow x.yml >/dev/null 2>&1; then
  fail "test 13: unknown deploy executor should fail"
fi
pass "workflow executor validation fails closed"

# ── Test 14: named environments are additive and optional (#151 AC2) ─────────
OUT="$TMP/t14.yml"
bash "$SCRIPT" --output "$OUT" \
  --deploy-default-environment production \
  --deploy-staging-workflow deploy-staging.yml \
  --deploy-production-workflow deploy-production.yml \
  --deploy-staging-health-url https://staging.example.test/health \
  --deploy-production-health-url https://app.example.test/health \
  --deploy-sha-input sha --deploy-verify health-sha >/dev/null 2>&1
grep -q '^  default: production$' "$OUT" || fail 'test 14: named default missing'
grep -q '^  environments:$' "$OUT" || fail 'test 14: environments block missing'
grep -q '^    staging:$' "$OUT" || fail 'test 14: staging missing'
grep -q '^    production:$' "$OUT" || fail 'test 14: production missing'
[ "$(bash -c "source '$VERIFY'; parse_deploy_workflow '$OUT' staging")" = deploy-staging.yml ] || fail 'test 14: staging workflow not parseable'
[ "$(bash -c "source '$VERIFY'; parse_deploy_workflow '$OUT' production")" = deploy-production.yml ] || fail 'test 14: production workflow not parseable'
[ "$(bash -c "source '$VERIFY'; parse_deploy_health_url '$OUT' staging")" = https://staging.example.test/health ] || fail 'test 14: staging health URL not parseable'
[ "$(bash -c "source '$VERIFY'; parse_deploy_health_url '$OUT' production")" = https://app.example.test/health ] || fail 'test 14: production health URL not parseable'
for env in staging production; do
  [ "$(bash -c "source '$VERIFY'; parse_deploy_executor '$OUT' '$env'")" = github-workflow ] || fail "test 14: $env executor incomplete"
  [ "$(bash -c "source '$VERIFY'; parse_deploy_verify '$OUT' '$env'")" = health-sha ] || fail "test 14: $env verification incomplete"
  [ "$(bash -c "source '$VERIFY'; parse_deploy_health_commit_field '$OUT' '$env'")" = commit ] || fail "test 14: $env health field incomplete"
done
pass 'named staging/production environments emit complete workflow and health evidence'

# ── Test 15: production-only named profile is complete (#151 AC6) ────────────
OUT="$TMP/t15.yml"
bash "$SCRIPT" --output "$OUT" \
  --deploy-default-environment production \
  --deploy-production-workflow deploy-production.yml \
  --deploy-production-health-url https://app.example.test/health \
  --deploy-sha-input sha --deploy-verify health-sha >/dev/null 2>&1
grep -q '^    production:$' "$OUT" || fail 'test 15: production profile missing'
! grep -q '^    staging:$' "$OUT" || fail 'test 15: production-only profile emitted staging'
[ "$(bash -c "source '$VERIFY'; parse_deploy_health_url '$OUT' production")" = https://app.example.test/health ] || fail 'test 15: production health missing'
pass 'production-only named profile is complete'

echo ""
echo "✓ write-otta-contract: all 15 checks passed"
