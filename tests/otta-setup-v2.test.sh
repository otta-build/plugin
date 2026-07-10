#!/usr/bin/env bash
# otta-setup-v2.test.sh — regression tests for scripts/write-otta-contract.sh (OTT-36).
# Asserts the v2 .otta.yml schema: tracker, autonomy, deploy, gates, telemetry, loops.
# Autonomy detection mirrors otta-engine/src/selfloop/repo_tier.py is_autonomy_eligible().
# Run: bash tests/otta-setup-v2.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/write-otta-contract.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$SCRIPT" ] || fail "write-otta-contract.sh not found at $SCRIPT (did you create it?)"

# ---------------------------------------------------------------------------
# Helper: init a minimal git repo and return its path
# ---------------------------------------------------------------------------
make_repo() {
  local path="$1"
  mkdir -p "$path"
  cd "$path"
  git init -q
  git config user.email t@t.t
  git config user.name t
  echo x > f; git add f; git commit -qm init
}

# =============================================================================
# AC1: script produces all 6 v2 schema keys in its output
# =============================================================================
REPO1="$TMP/repo-plain"
make_repo "$REPO1"
cd "$REPO1"
OUT="$(bash "$SCRIPT")" || fail "AC1: script exited non-zero on plain repo"
echo "$OUT" | grep -q '^tracker:' || fail "AC1: output missing 'tracker:' key"
echo "$OUT" | grep -q '^autonomy:' || fail "AC1: output missing 'autonomy:' key"
echo "$OUT" | grep -q '^deploy:' || fail "AC1: output missing 'deploy:' key"
echo "$OUT" | grep -q '^gates:' || fail "AC1: output missing 'gates:' key"
echo "$OUT" | grep -q '^telemetry:' || fail "AC1: output missing 'telemetry:' key"
echo "$OUT" | grep -q '^loops:' || fail "AC1: output missing 'loops:' key"
echo "✓ AC1: all 6 v2 schema keys present"

# =============================================================================
# AC2a: astro-only repo (root astro.config.mjs, no package.json) → autonomy: auto
# =============================================================================
REPO2="$TMP/repo-astro-only"
make_repo "$REPO2"
cd "$REPO2"
touch astro.config.mjs
OUT="$(bash "$SCRIPT")"
echo "$OUT" | grep -q '^autonomy: auto' || fail "AC2a: astro.config.mjs at root + no package.json must give autonomy: auto, got: $(echo "$OUT" | grep '^autonomy:')"
echo "✓ AC2a: astro-only repo (no package.json) → autonomy: auto"

# =============================================================================
# AC2b: astro-only repo (root astro.config.ts, package.json WITHOUT workspaces) → auto
# =============================================================================
REPO2B="$TMP/repo-astro-pkg"
make_repo "$REPO2B"
cd "$REPO2B"
touch astro.config.ts
echo '{"name":"site","version":"1.0.0"}' > package.json
OUT="$(bash "$SCRIPT")"
echo "$OUT" | grep -q '^autonomy: auto' || fail "AC2b: astro.config.ts + package.json-no-workspaces must give autonomy: auto, got: $(echo "$OUT" | grep '^autonomy:')"
echo "✓ AC2b: astro + package.json (no workspaces) → autonomy: auto"

# =============================================================================
# AC2c: astro-only repo (root astro.config.js, package.json WITH workspaces) → human-gated
# =============================================================================
REPO2C="$TMP/repo-astro-ws"
make_repo "$REPO2C"
cd "$REPO2C"
touch astro.config.js
echo '{"name":"monorepo","workspaces":["packages/*"]}' > package.json
OUT="$(bash "$SCRIPT")"
echo "$OUT" | grep -q '^autonomy: human-gated' || fail "AC2c: astro.config.js + workspaces must give autonomy: human-gated, got: $(echo "$OUT" | grep '^autonomy:')"
echo "✓ AC2c: astro + workspaces in package.json → autonomy: human-gated"

# =============================================================================
# AC2d: no root astro.config → human-gated (even if monorepo has nested astro)
# =============================================================================
REPO2D="$TMP/repo-no-astro"
make_repo "$REPO2D"
cd "$REPO2D"
mkdir -p apps/landing
touch apps/landing/astro.config.mjs   # nested, not at root
OUT="$(bash "$SCRIPT")"
echo "$OUT" | grep -q '^autonomy: human-gated' || fail "AC2d: nested astro.config (not root) must give autonomy: human-gated, got: $(echo "$OUT" | grep '^autonomy:')"
echo "✓ AC2d: no root astro.config (nested only) → autonomy: human-gated"

# =============================================================================
# AC3: fail-closed — malformed package.json → human-gated
# =============================================================================
REPO3="$TMP/repo-malformed"
make_repo "$REPO3"
cd "$REPO3"
touch astro.config.mjs
echo 'THIS IS NOT JSON {{{' > package.json
OUT="$(bash "$SCRIPT")"
echo "$OUT" | grep -q '^autonomy: human-gated' || fail "AC3: malformed package.json must fail closed (human-gated), got: $(echo "$OUT" | grep '^autonomy:')"
echo "✓ AC3: malformed package.json → autonomy: human-gated (fails closed)"

# =============================================================================
# AC4a: LINEAR_TEAM env var → tracker: {kind: linear, team: <value>}
# =============================================================================
REPO4A="$TMP/repo-linear-env"
make_repo "$REPO4A"
cd "$REPO4A"
OUT="$(LINEAR_TEAM=OTT bash "$SCRIPT")"
echo "$OUT" | grep -q 'kind: linear' || fail "AC4a: LINEAR_TEAM env → kind: linear, got: $(echo "$OUT" | grep 'tracker\|kind\|team')"
echo "$OUT" | grep -q 'team: OTT' || fail "AC4a: LINEAR_TEAM=OTT should write team: OTT, got: $(echo "$OUT" | grep 'team:')"
echo "✓ AC4a: LINEAR_TEAM env var → tracker {kind: linear, team: OTT}"

# =============================================================================
# AC4b: .selfloop.yml with team → tracker: {kind: linear, team: <from config>}
# =============================================================================
REPO4B="$TMP/repo-selfloop"
make_repo "$REPO4B"
cd "$REPO4B"
cat > .selfloop.yml <<'EOF'
team: LC
repo: wiselancer/leadcognition_v2
EOF
OUT="$(bash "$SCRIPT")"
echo "$OUT" | grep -q 'kind: linear' || fail "AC4b: .selfloop.yml with team: → kind: linear, got: $(echo "$OUT" | grep 'tracker\|kind\|team')"
echo "$OUT" | grep -q 'team: LC' || fail "AC4b: .selfloop.yml team:LC should write team: LC, got: $(echo "$OUT" | grep 'team:')"
echo "✓ AC4b: .selfloop.yml with team field → tracker {kind: linear, team: LC}"

# =============================================================================
# AC4c: no linear signals → tracker: {kind: gh}
# =============================================================================
REPO4C="$TMP/repo-gh-tracker"
make_repo "$REPO4C"
cd "$REPO4C"
# Ensure no LINEAR_TEAM in env for this call
OUT="$(env -u LINEAR_TEAM bash "$SCRIPT" 2>/dev/null || bash "$SCRIPT")"
echo "$OUT" | grep -q 'kind: gh' || fail "AC4c: no linear signals must yield tracker {kind: gh}, got: $(echo "$OUT" | grep 'kind:')"
echo "✓ AC4c: no linear signals → tracker {kind: gh}"

# =============================================================================
# AC5: gates always = [pr-body-acceptance, test-coverage, review-thread]
# =============================================================================
REPO5="$TMP/repo-gates"
make_repo "$REPO5"
cd "$REPO5"
OUT="$(bash "$SCRIPT")"
echo "$OUT" | grep -q 'pr-body-acceptance' || fail "AC5: gates missing pr-body-acceptance"
echo "$OUT" | grep -q 'test-coverage' || fail "AC5: gates missing test-coverage"
echo "$OUT" | grep -q 'review-thread' || fail "AC5: gates missing review-thread"
echo "✓ AC5: all 3 standard gates present"

# =============================================================================
# AC6a: no --seo-geo flag → loops: [dev_loop] only
# =============================================================================
REPO6A="$TMP/repo-loops-default"
make_repo "$REPO6A"
cd "$REPO6A"
OUT="$(bash "$SCRIPT")"
LOOPS_LINE="$(echo "$OUT" | grep '^loops:')"
echo "$LOOPS_LINE" | grep -q 'dev_loop' || fail "AC6a: loops must contain dev_loop, got: $LOOPS_LINE"
# seo_geo must NOT appear when flag is absent
echo "$LOOPS_LINE" | grep -qv 'seo_geo' || fail "AC6a: seo_geo must not appear in loops without --seo-geo flag, got: $LOOPS_LINE"
echo "✓ AC6a: default loops = [dev_loop] only"

# =============================================================================
# AC6b: --seo-geo flag → loops: [dev_loop, seo_geo]
# =============================================================================
REPO6B="$TMP/repo-loops-seo"
make_repo "$REPO6B"
cd "$REPO6B"
OUT="$(bash "$SCRIPT" --seo-geo)"
LOOPS_LINE="$(echo "$OUT" | grep '^loops:')"
echo "$LOOPS_LINE" | grep -q 'dev_loop' || fail "AC6b: loops must contain dev_loop with --seo-geo, got: $LOOPS_LINE"
echo "$LOOPS_LINE" | grep -q 'seo_geo' || fail "AC6b: loops must contain seo_geo with --seo-geo flag, got: $LOOPS_LINE"
echo "✓ AC6b: --seo-geo flag adds seo_geo to loops"

# =============================================================================
# AC7: setup.md B1 references write-otta-contract.sh
# =============================================================================
SETUP="$HERE/../commands/setup.md"
[ -f "$SETUP" ] || fail "AC7: setup.md not found at $SETUP"
grep -q "write-otta-contract.sh" "$SETUP" || fail "AC7: setup.md B1 must reference write-otta-contract.sh for the v2 contract"
echo "✓ AC7: setup.md references write-otta-contract.sh"

# =============================================================================
# Bonus: --output flag writes a file
# =============================================================================
REPO_OUT="$TMP/repo-output-flag"
make_repo "$REPO_OUT"
cd "$REPO_OUT"
OUTFILE="$TMP/contract.yml"
bash "$SCRIPT" --output "$OUTFILE" >/dev/null
[ -f "$OUTFILE" ] || fail "bonus: --output flag did not create file"
grep -q '^tracker:' "$OUTFILE" || fail "bonus: --output file missing tracker key"
grep -q '^autonomy:' "$OUTFILE" || fail "bonus: --output file missing autonomy key"
echo "✓ bonus: --output flag writes a file with schema"

# =============================================================================
# Bonus: YAML parses correctly (if python3 available)
# =============================================================================
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
  REPO_PY="$TMP/repo-yaml"
  make_repo "$REPO_PY"
  cd "$REPO_PY"
  touch astro.config.mjs
  bash "$SCRIPT" | python3 -c "
import yaml, sys
d = yaml.safe_load(sys.stdin)
assert 'tracker' in d, 'tracker key missing: ' + str(d.keys())
assert 'autonomy' in d, 'autonomy key missing: ' + str(d.keys())
assert d['autonomy'] == 'auto', 'astro-only must be auto, got: ' + repr(d['autonomy'])
assert 'deploy' in d, 'deploy key missing'
assert 'gates' in d, 'gates key missing'
assert isinstance(d['gates'], list), 'gates must be a list'
assert 'pr-body-acceptance' in d['gates'], 'pr-body-acceptance missing from gates: ' + str(d['gates'])
assert 'test-coverage' in d['gates'], 'test-coverage missing from gates: ' + str(d['gates'])
assert 'review-thread' in d['gates'], 'review-thread missing from gates: ' + str(d['gates'])
assert 'telemetry' in d, 'telemetry key missing'
assert 'loops' in d, 'loops key missing'
assert isinstance(d['loops'], list), 'loops must be a list'
assert 'dev_loop' in d['loops'], 'dev_loop missing from loops: ' + str(d['loops'])
print('  python3 YAML assertions: ok')
" || fail "YAML failed python3 schema assertion"
fi

# =============================================================================
# AC8: no phantom v1 fields in setup.md wizard prompts/summary
# The 6 field names emitted by write-otta-contract.sh are:
#   tracker, autonomy, deploy, gates, telemetry, loops
# The following OLD-schema fields must NOT appear anywhere in setup.md:
#   ci.required, pulse.installed, release.auto
# Note: deploy.auto is a VALID v2 sub-field of the deploy block (used by
#   otta-deploy-verify.sh and written by write-otta-contract.sh --deploy-auto).
#   It is intentionally referenced in the setup wizard (step 3) — do NOT add it
#   back to this phantom-field guard.
# For base/staging: check only the step-10 .otta.yml bullet for field refs.
# =============================================================================
SETUP="$HERE/../commands/setup.md"
grep -q 'ci\.required\|ci.required:' "$SETUP" \
  && fail "AC8: setup.md still references phantom field 'ci.required'"
grep -q 'pulse\.installed\|pulse.installed:' "$SETUP" \
  && fail "AC8: setup.md still references phantom field 'pulse.installed'"
grep -q 'release\.auto\|release.auto:' "$SETUP" \
  && fail "AC8: setup.md still references phantom field 'release.auto'"
# Extract the step-10 .otta.yml summary bullet (Markdown blockquote list item)
# and check for base:/staging: field refs
_step10_line="$(grep '^> - .*\.otta\.yml' "$SETUP" | head -1)"
echo "$_step10_line" | grep -q 'base:' \
  && fail "AC8: step-10 .otta.yml bullet still references phantom field 'base:'"
echo "$_step10_line" | grep -q 'staging:' \
  && fail "AC8: step-10 .otta.yml bullet still references phantom field 'staging:'"
echo "✓ AC8: no phantom v1 fields in setup.md wizard prompts/summary"

# =============================================================================
# AC9: step-10 .otta.yml summary bullet lists all 6 v2 schema keys
# =============================================================================
_step10_line="$(grep '^> - .*\.otta\.yml' "$SETUP" | head -1)"
[ -n "$_step10_line" ] || fail "AC9: could not find .otta.yml summary bullet in step 10"
echo "$_step10_line" | grep -q 'tracker'   || fail "AC9: step-10 .otta.yml bullet missing 'tracker'"
echo "$_step10_line" | grep -q 'autonomy'  || fail "AC9: step-10 .otta.yml bullet missing 'autonomy'"
echo "$_step10_line" | grep -q 'deploy'    || fail "AC9: step-10 .otta.yml bullet missing 'deploy'"
echo "$_step10_line" | grep -q 'gates'     || fail "AC9: step-10 .otta.yml bullet missing 'gates'"
echo "$_step10_line" | grep -q 'telemetry' || fail "AC9: step-10 .otta.yml bullet missing 'telemetry'"
echo "$_step10_line" | grep -q 'loops'     || fail "AC9: step-10 .otta.yml bullet missing 'loops'"
echo "✓ AC9: step-10 .otta.yml bullet lists all 6 v2 schema keys"

echo ""
echo "✓ otta-setup-v2: all checks passed"
