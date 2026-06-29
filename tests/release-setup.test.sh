#!/usr/bin/env bash
# release-setup.test.sh — tests for scripts/otta-release-setup.sh (issue #55)
# Covers: dry-run, create, idempotency
# Run: bash tests/release-setup.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-release-setup.sh"

fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

[ -f "$SCRIPT" ] || fail "otta-release-setup.sh not found at $SCRIPT"

WORKFLOW_PATH=".github/workflows/otta-release.yml"

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

[ ! -f "$TMPDIR1/$WORKFLOW_PATH" ] \
  || fail "dry-run: must NOT create $WORKFLOW_PATH"

pass "dry-run: exits 0, prints 'Would write', writes no file"

# ---------------------------------------------------------------------------
# Test 2: creates .github/workflows/otta-release.yml in a fresh repo dir
# ---------------------------------------------------------------------------
TMPDIR2="$(mktemp -d)"
trap 'rm -rf "$TMPDIR1" "$TMPDIR2"' EXIT

mkdir -p "$TMPDIR2"
printf '{"name":"test-pkg","version":"1.0.0"}' > "$TMPDIR2/package.json"

(cd "$TMPDIR2" && bash "$SCRIPT")

[ -f "$TMPDIR2/$WORKFLOW_PATH" ] \
  || fail "create: $WORKFLOW_PATH was not created"

grep -q "otta-release" "$TMPDIR2/$WORKFLOW_PATH" \
  || fail "create: $WORKFLOW_PATH does not contain expected workflow content"

grep -q "tag_name\|git tag\|VERSION" "$TMPDIR2/$WORKFLOW_PATH" \
  || fail "create: $WORKFLOW_PATH missing tagging logic"

pass "create: $WORKFLOW_PATH created with expected content"

# ---------------------------------------------------------------------------
# Test 3: idempotent — running twice does not overwrite the file
# ---------------------------------------------------------------------------
# Modify the file to detect overwrite
printf 'sentinel line\n' >> "$TMPDIR2/$WORKFLOW_PATH"
MODIFIED_CONTENT="$(cat "$TMPDIR2/$WORKFLOW_PATH")"

(cd "$TMPDIR2" && bash "$SCRIPT") 2>&1

AFTER_SECOND_RUN="$(cat "$TMPDIR2/$WORKFLOW_PATH")"

[ "$AFTER_SECOND_RUN" = "$MODIFIED_CONTENT" ] \
  || fail "idempotent: second run overwrote existing file (content changed)"

pass "idempotent: second run skips existing file"

# ---------------------------------------------------------------------------
# Test 4: second run exits 0 (not an error to find existing file)
# ---------------------------------------------------------------------------
EXIT_IDEMPOTENT=0
(cd "$TMPDIR2" && bash "$SCRIPT") || EXIT_IDEMPOTENT=$?

[ "$EXIT_IDEMPOTENT" -eq 0 ] \
  || fail "idempotent: second run must exit 0, got $EXIT_IDEMPOTENT"

pass "idempotent: second run exits 0"

echo ""
echo "✓ release-setup: all checks passed (dry-run + create + idempotency)"
