#!/usr/bin/env bash
# otta-bypass-detect-setup.test.sh — tests for scripts/otta-bypass-detect-setup.sh
# (issue #202). Covers AC5 (opt-in installer) plus the runner/default-branch
# inference and allowlist configurability that make the installed workflow
# usable across repos. Pattern matches tests/release-setup.test.sh and
# tests/release-setup-runner.test.sh.
# Run: bash tests/otta-bypass-detect-setup.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-bypass-detect-setup.sh"
DETECT_SCRIPT="$HERE/../scripts/otta-bypass-detect.sh"

fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

[ -f "$SCRIPT" ] || fail "otta-bypass-detect-setup.sh not found at $SCRIPT"

WORKFLOW_PATH=".github/workflows/otta-bypass-detect.yml"

# ---------------------------------------------------------------------------
# Test 1: --dry-run exits 0, prints "Would write", writes no file
# ---------------------------------------------------------------------------
TMPDIR1="$(mktemp -d)"
trap 'rm -rf "$TMPDIR1"' EXIT

EXIT_CODE=0
(cd "$TMPDIR1" && bash "$SCRIPT" --dry-run) || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 0 ] || fail "dry-run: expected exit 0, got $EXIT_CODE"

DRY_OUTPUT="$(cd "$TMPDIR1" && bash "$SCRIPT" --dry-run 2>&1)"
echo "$DRY_OUTPUT" | grep -qi "Would write" \
  || fail "dry-run: output must contain 'Would write' (got: $DRY_OUTPUT)"

[ ! -f "$TMPDIR1/$WORKFLOW_PATH" ] || fail "dry-run: must NOT create $WORKFLOW_PATH"

pass "dry-run: exits 0, prints 'Would write', writes no file"

# ---------------------------------------------------------------------------
# Test 2: creates the workflow in a fresh repo dir; AC5 — opt-in only, so a
# repo with no other otta workflows must be untouched by anything but this file.
# ---------------------------------------------------------------------------
TMPDIR2="$(mktemp -d)"
trap 'rm -rf "$TMPDIR1" "$TMPDIR2"' EXIT

(cd "$TMPDIR2" && bash "$SCRIPT")

[ -f "$TMPDIR2/$WORKFLOW_PATH" ] || fail "create: $WORKFLOW_PATH was not created"
FILE_COUNT="$(find "$TMPDIR2/.github/workflows" -type f | wc -l | tr -d ' ')"
[ "$FILE_COUNT" -eq 1 ] || fail "opt-in: only the one workflow file should exist, found $FILE_COUNT"

grep -q "on push to main branch\|branches:" "$TMPDIR2/$WORKFLOW_PATH" \
  || fail "create: $WORKFLOW_PATH missing a push trigger"

grep -q "issues: write" "$TMPDIR2/$WORKFLOW_PATH" \
  || fail "create: $WORKFLOW_PATH missing 'issues: write' permission"
grep -q "contents: read" "$TMPDIR2/$WORKFLOW_PATH" \
  || fail "create: $WORKFLOW_PATH missing 'contents: read' permission"
# Review finding #1: once a workflow declares a `permissions:` block, every
# unlisted scope is forced to `none`. GET commits/{sha}/pulls needs
# `pull-requests: read` for GITHUB_TOKEN — without it the lookup 403s on
# exactly the private-repo case this issue exists for.
grep -q "pull-requests: read" "$TMPDIR2/$WORKFLOW_PATH" \
  || fail "create: $WORKFLOW_PATH missing 'pull-requests: read' permission (needed for commits/{sha}/pulls)"

grep -q "fetch-depth: 0" "$TMPDIR2/$WORKFLOW_PATH" \
  || fail "create: $WORKFLOW_PATH must fetch full history (needed for before..after diff)"

grep -q "commits/.*pulls" "$TMPDIR2/$WORKFLOW_PATH" \
  || fail "create: $WORKFLOW_PATH must call the commits/{sha}/pulls API"

# The installed workflow embeds the exact tested detection script verbatim —
# no separate scripts/ dependency in the consuming repo. Spot-check a
# distinctive function definition made it into the run: block.
grep -q "_process_commit()" "$TMPDIR2/$WORKFLOW_PATH" \
  || fail "create: $WORKFLOW_PATH does not embed the detection script's functions"

pass "create: $WORKFLOW_PATH created, opt-in only, self-contained, correctly permissioned"

# ---------------------------------------------------------------------------
# Test 3: idempotent — running twice does not overwrite the file
# ---------------------------------------------------------------------------
printf 'sentinel line\n' >> "$TMPDIR2/$WORKFLOW_PATH"
MODIFIED_CONTENT="$(cat "$TMPDIR2/$WORKFLOW_PATH")"

(cd "$TMPDIR2" && bash "$SCRIPT") 2>&1

AFTER_SECOND_RUN="$(cat "$TMPDIR2/$WORKFLOW_PATH")"
[ "$AFTER_SECOND_RUN" = "$MODIFIED_CONTENT" ] \
  || fail "idempotent: second run overwrote existing file (content changed)"

EXIT_IDEMPOTENT=0
(cd "$TMPDIR2" && bash "$SCRIPT") || EXIT_IDEMPOTENT=$?
[ "$EXIT_IDEMPOTENT" -eq 0 ] || fail "idempotent: second run must exit 0, got $EXIT_IDEMPOTENT"

pass "idempotent: second run skips existing file and exits 0"

# ---------------------------------------------------------------------------
# Test 4: runner inference — mirrors release-setup-runner.test.sh's finding
# that a hardcoded ubuntu-latest silently breaks self-hosted-only repos.
# ---------------------------------------------------------------------------
mk_repo() { # $1 = name, $2 = runs-on value (empty = no workflows)
  local d="$TMPDIR2/$1"
  mkdir -p "$d"
  if [ -n "${2:-}" ]; then
    mkdir -p "$d/.github/workflows"
    printf 'name: ci\non: [push]\njobs:\n  test:\n    runs-on: %s\n    steps:\n      - run: true\n' \
      "$2" > "$d/.github/workflows/ci.yml"
  fi
  printf '%s' "$d"
}
generated_runs_on() {
  grep -E '^[[:space:]]*runs-on:' "$1/$WORKFLOW_PATH" \
    | head -1 | sed -E 's/^[[:space:]]*runs-on:[[:space:]]*//; s/[[:space:]]+$//'
}

R="$(mk_repo selfhosted '[self-hosted, linux]')"
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "setup failed on a self-hosted repo"
got="$(generated_runs_on "$R")"
[ "$got" = "[self-hosted, linux]" ] || fail "expected inherited runner, got '$got'"

R="$(mk_repo bare '')"
out="$( cd "$R" && bash "$SCRIPT" 2>&1 )" || fail "setup failed on a repo with no workflows"
got="$(generated_runs_on "$R")"
[ "$got" = "ubuntu-latest" ] || fail "expected fallback 'ubuntu-latest', got '$got'"
printf '%s' "$out" | grep -qi 'ubuntu-latest' \
  || fail "fallback must report the assumed runner on stdout; got: $out"

R="$(mk_repo override 'ubuntu-latest')"
( cd "$R" && bash "$SCRIPT" --runner 'macos-14' >/dev/null 2>&1 ) || fail "--runner failed"
got="$(generated_runs_on "$R")"
[ "$got" = "macos-14" ] || fail "--runner should win over inference, got '$got'"

pass "runner: inferred from existing workflows, falls back to ubuntu-latest, --runner overrides"

# ---------------------------------------------------------------------------
# Test 5: default-branch inference and --default-branch override
# ---------------------------------------------------------------------------
generated_branch() {
  grep -A2 '^  push:' "$1/$WORKFLOW_PATH" | grep 'branches:' \
    | sed -E "s/.*branches:[[:space:]]*\[//; s/\].*//"
}

R="$TMPDIR2/gitrepo"
mkdir -p "$R"
( cd "$R" && git init -q && git symbolic-ref HEAD refs/heads/trunk )
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "setup failed inferring default branch"
got="$(generated_branch "$R")"
[ "$got" = "trunk" ] || fail "expected inferred default branch 'trunk', got '$got'"

R="$TMPDIR2/branchoverride"
mkdir -p "$R"
( cd "$R" && bash "$SCRIPT" --default-branch develop >/dev/null 2>&1 ) || fail "--default-branch failed"
got="$(generated_branch "$R")"
[ "$got" = "develop" ] || fail "--default-branch should win, got '$got'"

R="$TMPDIR2/nogit"
mkdir -p "$R"
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "setup failed with no git repo"
got="$(generated_branch "$R")"
[ "$got" = "main" ] || fail "expected fallback default branch 'main', got '$got'"

pass "default-branch: inferred from the repo's HEAD, falls back to main, --default-branch overrides"

# ---------------------------------------------------------------------------
# Test 6: --allowlist seeds the ALLOWLIST env, configurable per repo (AC3)
# ---------------------------------------------------------------------------
R="$TMPDIR2/allowlisted"
mkdir -p "$R"
( cd "$R" && bash "$SCRIPT" --allowlist 'deploy-bot,release-bot[bot]' >/dev/null 2>&1 ) || fail "--allowlist failed"
grep -q 'deploy-bot,release-bot\[bot\]' "$R/$WORKFLOW_PATH" \
  || fail "custom --allowlist value not present in generated workflow"

R="$TMPDIR2/defaultallow"
mkdir -p "$R"
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "default install failed"
grep -q 'github-actions\[bot\]' "$R/$WORKFLOW_PATH" \
  || fail "default allowlist must include github-actions[bot] (the common release-bot case)"

pass "allowlist: --allowlist overrides the default, default covers github-actions[bot]"

# ---------------------------------------------------------------------------
# Test 7: the embedded detection script content matches the tested source
# file byte-for-byte (installer must not drift from what tests actually run).
# ---------------------------------------------------------------------------
R="$TMPDIR2/embed-check"
mkdir -p "$R"
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "setup failed for embed check"

# Extract everything between the sentinel markers the installer wraps the
# embedded script in, and diff (ignoring leading run: indentation) against
# the real source of truth.
awk '/# --- otta-bypass-detect.sh begin ---/{f=1;next}/# --- otta-bypass-detect.sh end ---/{f=0}f' \
  "$R/$WORKFLOW_PATH" | sed -E 's/^          //' > "$TMPDIR2/embedded.sh"
diff -q "$TMPDIR2/embedded.sh" "$DETECT_SCRIPT" >/dev/null \
  || fail "embedded detection script has drifted from scripts/otta-bypass-detect.sh"

pass "embed: generated workflow embeds scripts/otta-bypass-detect.sh verbatim"

echo ""
echo "✓ otta-bypass-detect-setup: all checks passed"
