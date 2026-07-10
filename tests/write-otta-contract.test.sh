#!/usr/bin/env bash
# write-otta-contract.test.sh — unit tests for write-otta-contract.sh
# Covers the deploy.auto + allow_production output (issue #101 AC2) and
# validates that otta-deploy-verify.sh can parse the generated contract.
# Run: bash tests/write-otta-contract.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/write-otta-contract.sh"
VERIFY="$HERE/../scripts/otta-deploy-verify.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

# Source the parse helpers from otta-deploy-verify.sh.
# The script uses 'set -euo pipefail' and has a main guard, so we source it
# and rely on parse_deploy_auto / parse_deploy_allow_production being exported.
# shellcheck source=/dev/null
# Wrap source to capture only function definitions (not execution side-effects).
(
  # The verify script may try to exec git etc on sourcing — run from a tmp dir
  # that is a git repo so git commands don't error.
  cd "$TMP"
  git init -q
  # Source in a subshell just to test parsing helpers are loadable.
  bash -c "source '$VERIFY' 2>/dev/null; parse_deploy_auto '$TMP/nope.yml'" 2>/dev/null \
    | grep -q "human-approve" \
    || fail "parse_deploy_auto helper not loadable from otta-deploy-verify.sh"
)

# ── Test 1: default output — auto=human-approve, no allow_production ─────────
OUT="$TMP/t1.yml"
bash "$SCRIPT" --output "$OUT" >/dev/null 2>&1
grep -q "auto: human-approve" "$OUT" || fail "test 1: default auto not human-approve"
grep -q "allow_production" "$OUT" && fail "test 1: allow_production should be absent by default" || true
pass "default: auto=human-approve, allow_production absent"

# ── Test 2: merge-on-green ────────────────────────────────────────────────────
OUT="$TMP/t2.yml"
bash "$SCRIPT" --output "$OUT" --deploy-auto merge-on-green >/dev/null 2>&1
grep -q "auto: merge-on-green" "$OUT" || fail "test 2: auto not merge-on-green"
grep -q "allow_production" "$OUT" && fail "test 2: allow_production should be absent" || true
pass "--deploy-auto merge-on-green: written correctly"

# ── Test 3: merge-and-deploy + allow-production ───────────────────────────────
OUT="$TMP/t3.yml"
bash "$SCRIPT" --output "$OUT" --deploy-auto merge-and-deploy --allow-production >/dev/null 2>&1
grep -q "auto: merge-and-deploy" "$OUT" || fail "test 3: auto not merge-and-deploy"
grep -q "allow_production: true" "$OUT" || fail "test 3: allow_production: true not written"
pass "--deploy-auto merge-and-deploy --allow-production: both keys written"

# ── Test 4: otta-deploy-verify.sh parses the generated contract ───────────────
# Use a sub-shell to isolate the parse_deploy_auto / parse_deploy_allow_production
# helpers without running the main merge logic of the script.
OUT="$TMP/t4.yml"
bash "$SCRIPT" --output "$OUT" --deploy-auto merge-on-green --deploy-target coolify --deploy-project myapp >/dev/null 2>&1
auto_val="$(bash -c "source '$VERIFY' 2>/dev/null; parse_deploy_auto '$OUT'")"
[ "$auto_val" = "merge-on-green" ] || fail "test 4: parse_deploy_auto returned '$auto_val', expected merge-on-green"
pass "otta-deploy-verify parse_deploy_auto reads generated contract correctly"

# ── Test 5: allow_production only emitted on --allow-production ───────────────
OUT="$TMP/t5.yml"
bash "$SCRIPT" --output "$OUT" --deploy-auto merge-and-deploy >/dev/null 2>&1
grep -q "allow_production" "$OUT" && fail "test 5: allow_production must not appear without --allow-production flag" || true
pass "allow_production absent when --allow-production not passed"

# ── Test 6: invalid deploy-auto value rejected ────────────────────────────────
if bash "$SCRIPT" --deploy-auto invalid-value >/dev/null 2>&1; then
  fail "test 6: invalid --deploy-auto value should have exited non-zero"
fi
pass "invalid --deploy-auto value → non-zero exit"

echo ""
echo "✓ write-otta-contract: all 6 checks passed"
