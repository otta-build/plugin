#!/usr/bin/env bash
# check-ac-layers.test.sh — isolated unit tests for scripts/check-ac-layers.sh
# Covers: [ui-layer]/[e2e] unit-test-only evidence rejection (AC1),
# warning for unclosed ui-layer with closed data-layer (AC3), and pass cases.
# Run: bash tests/check-ac-layers.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/check-ac-layers.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

# Helper: write a temp pr-body
body() { local f="$TMP/$1"; printf '%s\n' "${@:2}" >"$f"; echo "$f"; }

# ── Test 1: no AC tags → passes ───────────────────────────────────────────────
F="$(body t1.md \
  '```acceptance' \
  '- [x] AC1: something — unit test passed' \
  '```')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 || fail "test 1: no layer tags should pass"
pass "no layer tags → pass"

# ── Test 2: [ui-layer] AC with preview URL passes ─────────────────────────────
F="$(body t2.md \
  '- [x] AC1 [ui-layer]: button renders — https://preview.example.com shows green')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 || fail "test 2: ui-layer with preview URL should pass"
pass "[ui-layer] with preview URL → pass"

# ── Test 3: [ui-layer] AC with unit-test-only evidence fails ─────────────────
F="$(body t3.md \
  '- [x] AC1 [ui-layer]: button renders — npm run test passed')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 && fail "test 3: ui-layer with unit test evidence should fail" || true
pass "[ui-layer] with unit-test-only evidence → fail"

# ── Test 4: [e2e] AC with unit-test-only evidence fails ──────────────────────
F="$(body t4.md \
  '- [x] AC1 [e2e]: user can log in — jest tests passed')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 && fail "test 4: e2e with unit test evidence should fail" || true
pass "[e2e] with unit-test-only evidence → fail"

# ── Test 5: [e2e] AC with e2e evidence passes ─────────────────────────────────
F="$(body t5.md \
  '- [x] AC1 [e2e]: user can log in — playwright login flow passes')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 || fail "test 5: e2e with playwright evidence should pass"
pass "[e2e] with playwright evidence → pass"

# ── Test 6: [data-layer] AC with unit test passes ────────────────────────────
F="$(body t6.md \
  '- [x] AC1 [data-layer]: schema migrates — unit test passed')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 || fail "test 6: data-layer with unit test should pass"
pass "[data-layer] with unit test → pass"

# ── Test 7: unchecked [ui-layer] with closed [data-layer] emits warning ──────
F="$(body t7.md \
  '- [x] AC1 [data-layer]: schema done — unit test passed' \
  '- [ ] AC2 [ui-layer]: page loads — not done')"
output="$(bash "$SCRIPT" "$F" 2>&1)"
# exit code still 0 (warning, not failure)
bash "$SCRIPT" "$F" >/dev/null 2>&1 || fail "test 7: unclosed ui-layer warning should not fail exit code"
echo "$output" | grep -q "unclosed" || fail "test 7: expected 'unclosed' warning in output"
pass "unclosed [ui-layer] with closed [data-layer] → warning (exit 0)"

# ── Test 8: no pr-body → passes with skip message ────────────────────────────
bash "$SCRIPT" "$TMP/nonexistent.md" >/dev/null 2>&1 || fail "test 8: missing file should pass (skipped)"
pass "missing file → pass (skipped)"

# ── Test 9: unchecked item with [ui-layer] is not flagged as AC1 violation ───
F="$(body t9.md \
  '- [ ] AC1 [ui-layer]: button renders — not done yet')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 || fail "test 9: unchecked ui-layer should not fail"
pass "unchecked [ui-layer] AC → no AC1 violation"

echo ""
echo "✓ check-ac-layers: all 9 checks passed"
