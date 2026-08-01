#!/usr/bin/env bash
# check-pr-body.test.sh — isolated unit tests for scripts/check-pr-body.sh
# Covers acceptance-block, Fixes #N, idea_ref checks, and stale-issue guard.
# Run: bash tests/check-pr-body.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/check-pr-body.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

# Helper: write a temp pr-body
body() { local f="$TMP/$1"; printf '%s\n' "${@:2}" >"$f"; echo "$f"; }

# ── Test 1: valid body passes ─────────────────────────────────────────────────
F="$(body t1.md \
  '```acceptance' \
  'GIVEN a repo' \
  'WHEN pushed' \
  'THEN passes' \
  '```' \
  '' \
  'idea_ref: issue:#99' \
  '' \
  'Fixes #99')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 || fail "test 1: valid body should pass"
pass "valid body passes"

# ── Test 2: missing acceptance block fails ────────────────────────────────────
F="$(body t2.md \
  'No acceptance block here' \
  'idea_ref: issue:#1' \
  'Fixes #1')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 && fail "test 2: missing acceptance block should fail" || true
pass "missing acceptance block → fail"

# ── Test 3: missing Fixes #N fails ───────────────────────────────────────────
F="$(body t3.md \
  '```acceptance' \
  'GIVEN x WHEN y THEN z' \
  '```' \
  'idea_ref: issue:#1')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 && fail "test 3: missing Fixes #N should fail" || true
pass "missing Fixes #N → fail"

# ── Test 4: missing idea_ref fails ───────────────────────────────────────────
F="$(body t4.md \
  '```acceptance' \
  'GIVEN x WHEN y THEN z' \
  '```' \
  'Fixes #1')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 && fail "test 4: missing idea_ref should fail" || true
pass "missing idea_ref → fail"

# ── Test 5: idea_ref with placeholder comment fails ───────────────────────────
F="$(body t5.md \
  '```acceptance' \
  'GIVEN x WHEN y THEN z' \
  '```' \
  'idea_ref: <!-- replace -->' \
  'Fixes #1')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 && fail "test 5: placeholder idea_ref should fail" || true
pass "placeholder idea_ref comment → fail"

# ── Test 6: all three checks reported together ────────────────────────────────
F="$(body t6.md 'nothing useful here')"
output="$(bash "$SCRIPT" "$F" 2>&1 || true)"
echo "$output" | grep -q "acceptance" || fail "test 6: expected acceptance error in output"
echo "$output" | grep -q "Fixes" || fail "test 6: expected Fixes error in output"
echo "$output" | grep -q "idea_ref" || fail "test 6: expected idea_ref error in output"
pass "all three errors reported together"

# ── Test 7: missing body file fails ──────────────────────────────────────────
bash "$SCRIPT" "$TMP/nonexistent.md" >/dev/null 2>&1 && fail "test 7: missing file should fail" || true
pass "missing file → fail"

# ── Test 8: idea_ref with real value passes even with extra whitespace ────────
# Use a high issue number (99999) that doesn't exist so the stale-issue guard
# returns an empty state (gh returns non-zero → || true → no CLOSED check).
F="$(body t8.md \
  '```acceptance' \
  'GIVEN x WHEN y THEN z' \
  '```' \
  'idea_ref:   linear:ABC-123' \
  'Fixes #99999')"
bash "$SCRIPT" "$F" >/dev/null 2>&1 || fail "test 8: idea_ref with leading whitespace should pass"
pass "idea_ref with whitespace → pass"

echo ""
echo "✓ check-pr-body: all 8 checks passed"

# ── Test: a gitignored .pr-body.md is skipped, not failed ────────────────────
# Repos that untracked .pr-body.md (leadcognition_v2#3001, otta-engine#160)
# validate the real PR body in CI. Demanding the file there blocks every push.
REPO="$TMP/ignored-repo"
mkdir -p "$REPO" && (cd "$REPO" && git init -q && echo '.pr-body.md' > .gitignore)
( cd "$REPO" && bash "$SCRIPT" .pr-body.md >/dev/null 2>&1 ) \
  || fail "gitignored .pr-body.md must be skipped, not fail the gate"
pass "gitignored .pr-body.md is skipped"

# ── Test: a missing, NOT-ignored .pr-body.md still fails ─────────────────────
REPO2="$TMP/normal-repo"
mkdir -p "$REPO2" && (cd "$REPO2" && git init -q)
if ( cd "$REPO2" && bash "$SCRIPT" .pr-body.md >/dev/null 2>&1 ); then
  fail "a missing .pr-body.md must still fail where the repo expects it"
fi
pass "missing .pr-body.md still fails where it is expected"
