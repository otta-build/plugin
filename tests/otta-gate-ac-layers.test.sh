#!/usr/bin/env bash
# otta-gate-ac-layers.test.sh — AC1/AC2/AC3: layer tag evidence enforcement in otta-gate.sh.
#
# AC1: [ui-layer]/[e2e] AC with unit-test-only evidence → gate fails with specific message.
# AC2: [data-layer] AC with unit-test-only evidence → gate passes.
# AC3: unclosed [ui-layer] ACs while only [data-layer] ACs closed → gate warns, still passes.
#
# Run: bash tests/otta-gate-ac-layers.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/../scripts/otta-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

[ -f "$GATE" ] || fail "otta-gate.sh not found at $GATE"

# ---------------------------------------------------------------------------
# Helper: create a minimal git repo in $1 with one commit so the diff is empty
# (empty diff → check-test-coverage exits 0 "no changes to gate yet").
# Then write .pr-body.md content from stdin.
# ---------------------------------------------------------------------------
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  cd "$dir"
  git init -q
  git config user.email t@t.t
  git config user.name t
  echo "placeholder" > placeholder.txt
  git add placeholder.txt
  git commit -qm "init" >/dev/null 2>&1
  # root = HEAD → empty diff → test-coverage check passes automatically
}

# ---------------------------------------------------------------------------
# Minimal valid acceptance block (check-pr-body.sh requirements):
#   - ```acceptance fenced block
#   - Fixes #N
#   - idea_ref: issue:#N (real value, not a placeholder)
# ---------------------------------------------------------------------------
VALID_PREAMBLE='## Summary
- test pr

```acceptance
GIVEN the system is running
WHEN an action occurs
THEN something observable happens
'
VALID_POSTAMBLE='
## Out of scope
- nothing

## Verification
- unit: bash tests/placeholder.test.sh

```

idea_ref: issue:#65

Fixes #65'

# =============================================================================
# 1. AC1: [ui-layer] AC with bash tests/foo.test.sh evidence → gate must FAIL
#    with the exact message.
# =============================================================================
REPO1="$TMP/ac1_ui"
make_repo "$REPO1"
cat > .pr-body.md <<EOF
${VALID_PREAMBLE}- [x] AC1 [ui-layer]: Given the UI loads — bash tests/unit.test.sh
${VALID_POSTAMBLE}
EOF

OUT1="$(OTTA_NO_CAPTURE=1 bash "$GATE" ".pr-body.md" 2>&1)" && STATUS1=0 || STATUS1=$?
[ "$STATUS1" -ne 0 ] \
  || fail "AC1-ui: expected gate to fail (exit non-zero), but it passed; output:\n$OUT1"
echo "$OUT1" | grep -qF "AC tagged [ui-layer]/[e2e] requires preview URL or e2e evidence — unit test insufficient." \
  || fail "AC1-ui: exact message missing; got:\n$OUT1"
pass "AC1 [ui-layer] with unit-test evidence → gate fails with correct message"

# =============================================================================
# 2. AC1: [e2e] AC with 'npm run test' evidence → gate must FAIL
# =============================================================================
REPO2="$TMP/ac1_e2e"
make_repo "$REPO2"
cat > .pr-body.md <<EOF
${VALID_PREAMBLE}- [x] AC1 [e2e]: Given a full user flow — npm run test
${VALID_POSTAMBLE}
EOF

OUT2="$(OTTA_NO_CAPTURE=1 bash "$GATE" ".pr-body.md" 2>&1)" && STATUS2=0 || STATUS2=$?
[ "$STATUS2" -ne 0 ] \
  || fail "AC1-e2e: expected gate to fail, but it passed; output:\n$OUT2"
echo "$OUT2" | grep -qF "AC tagged [ui-layer]/[e2e] requires preview URL or e2e evidence — unit test insufficient." \
  || fail "AC1-e2e: exact message missing; got:\n$OUT2"
pass "AC1 [e2e] with 'npm run test' evidence → gate fails with correct message"

# =============================================================================
# 3. AC2: [data-layer] AC with unit test evidence → gate must PASS
# =============================================================================
REPO3="$TMP/ac2_data"
make_repo "$REPO3"
cat > .pr-body.md <<EOF
${VALID_PREAMBLE}- [x] AC1 [data-layer]: Given schema migrations run — bash tests/schema.test.sh
${VALID_POSTAMBLE}
EOF

OUT3="$(OTTA_NO_CAPTURE=1 bash "$GATE" ".pr-body.md" 2>&1)" && STATUS3=0 || STATUS3=$?
[ "$STATUS3" -eq 0 ] \
  || fail "AC2: expected gate to pass, but it failed (exit $STATUS3); output:\n$OUT3"
pass "AC2 [data-layer] with unit test evidence → gate passes"

# =============================================================================
# 4. AC3: unclosed [ui-layer] AC + only [data-layer] closed → gate PASSES with warning
# =============================================================================
REPO4="$TMP/ac3_warn"
make_repo "$REPO4"
cat > .pr-body.md <<EOF
${VALID_PREAMBLE}- [x] AC1 [data-layer]: Given schema migrations run — bash tests/schema.test.sh
- [ ] AC2 [ui-layer]: Given the page renders
${VALID_POSTAMBLE}
EOF

OUT4="$(OTTA_NO_CAPTURE=1 bash "$GATE" ".pr-body.md" 2>&1)" && STATUS4=0 || STATUS4=$?
[ "$STATUS4" -eq 0 ] \
  || fail "AC3: expected gate to PASS (warning only, exit 0), but it exited $STATUS4; output:\n$OUT4"
echo "$OUT4" | grep -qF "Issue has unclosed [ui-layer]/[e2e] ACs — issue will remain open after merge." \
  || fail "AC3: warning message missing; got:\n$OUT4"
pass "AC3 unclosed [ui-layer] + only [data-layer] closed → gate passes with warning"

# =============================================================================
# 5. AC1 does NOT fire on an unchecked [ui-layer] AC (only checked lines trigger)
# =============================================================================
REPO5="$TMP/ac1_unchecked"
make_repo "$REPO5"
cat > .pr-body.md <<EOF
${VALID_PREAMBLE}- [ ] AC1 [ui-layer]: Given the UI loads — bash tests/unit.test.sh
${VALID_POSTAMBLE}
EOF

OUT5="$(OTTA_NO_CAPTURE=1 bash "$GATE" ".pr-body.md" 2>&1)" && STATUS5=0 || STATUS5=$?
[ "$STATUS5" -eq 0 ] \
  || fail "AC1-unchecked: unchecked [ui-layer] should NOT trigger failure; got exit $STATUS5; output:\n$OUT5"
pass "unchecked [ui-layer] AC with unit-test evidence → gate passes (not checked = not evidence)"

# =============================================================================
# 6. AC4: seed-pr-body.sh preserves layer tags + adds layer key note when present
# =============================================================================
SEED="$HERE/../scripts/seed-pr-body.sh"
[ -f "$SEED" ] || fail "seed-pr-body.sh not found at $SEED"

REPO6="$TMP/ac4_seed"
mkdir -p "$REPO6"
cd "$REPO6"

# Stub gh: repo view → org/repo, issue view → body with layer-tagged ACs
FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"
# Write the issue JSON to a file so the stub can cat it (avoids shell escaping of \n in JSON)
python3 -c "
import json, sys
body = '- [ ] AC1 [data-layer]: Given schema runs\n- [ ] AC2 [ui-layer]: Given the page loads'
print(json.dumps({'number': 65, 'title': 'Add AC layer tags', 'body': body}))
" > "$FAKE_BIN/issue.json"
cat > "$FAKE_BIN/gh" <<GHEOF
#!/bin/sh
case "\$*" in
  *"repo view"*) echo '{"nameWithOwner":"test/repo"}' ;;
  *"issue view"*) cat "$FAKE_BIN/issue.json" ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$FAKE_BIN/gh"

OUT6="$(PATH="$FAKE_BIN:$PATH" bash "$SEED" 65 2>&1)" && STATUS6=0 || STATUS6=$?
[ "$STATUS6" -eq 0 ] || fail "AC4: seed-pr-body.sh exited $STATUS6; output:\n$OUT6"

[ -f ".pr-body.md" ] || fail "AC4: .pr-body.md not created"
BODY6="$(cat .pr-body.md)"

# Layer tags preserved
echo "$BODY6" | grep -qF "[data-layer]" || fail "AC4: [data-layer] tag not in seeded body"
echo "$BODY6" | grep -qF "[ui-layer]" || fail "AC4: [ui-layer] tag not in seeded body"

# Layer key note added
echo "$BODY6" | grep -qF "AC layer key:" || fail "AC4: layer key note missing from seeded body"
echo "$BODY6" | grep -qF "[data-layer] — schema + mutations" || fail "AC4: layer key data-layer definition missing"
echo "$BODY6" | grep -qF "[ui-layer]   — requires working page" || fail "AC4: layer key ui-layer definition missing"
echo "$BODY6" | grep -qF "[e2e]        — requires full user flow" || fail "AC4: layer key e2e definition missing"
pass "AC4 seed-pr-body.sh preserves layer tags and adds layer key note"

# =============================================================================
# 7. AC5: otta-gate.sh --help includes layer key
# =============================================================================
OUT7="$(bash "$GATE" --help 2>&1)" && STATUS7=0 || STATUS7=$?
[ "$STATUS7" -eq 0 ] || fail "AC5: otta-gate.sh --help exited $STATUS7"
echo "$OUT7" | grep -qF "[data-layer]" || fail "AC5: [data-layer] missing from help output"
echo "$OUT7" | grep -qF "[ui-layer]" || fail "AC5: [ui-layer] missing from help output"
echo "$OUT7" | grep -qF "[e2e]" || fail "AC5: [e2e] missing from help output"
pass "AC5 otta-gate.sh --help includes layer key definition"

echo ""
echo "✓ otta-gate-ac-layers: all layer tag checks passed"
