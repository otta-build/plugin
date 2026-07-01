#!/usr/bin/env bash
# Structural regression test for the Verify stage in workflows/otta-build.mjs.
# /otta:build is unattended (Workflow-orchestrated, no human to pause for), so
# it must NOT reuse the interactive `run` skill (which depends on a local
# claude-in-chrome session). It must instead self-verify UI changes headlessly
# via Playwright, scoped to frontend changes and skippable otherwise.
# Run: bash plugins/otta/tests/build-visual-verify.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_MJS="$HERE/../workflows/otta-build.mjs"

fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$BUILD_MJS" ] || fail "otta-build.mjs not found at $BUILD_MJS"

# 1. Uses headless Playwright, not the interactive `run` skill / claude-in-chrome
grep -qi "playwright" "$BUILD_MJS" \
  || fail "otta-build.mjs does not wire a headless UI check (expected Playwright MCP)"
grep -qi "claude-in-chrome" "$BUILD_MJS" \
  && fail "otta-build.mjs must not depend on claude-in-chrome — no local browser session in unattended runs"

# 2. Explicitly unattended (no local Chrome session required)
grep -qiE "no local chrome|unattended" "$BUILD_MJS" \
  || fail "otta-build.mjs does not state the UI check runs unattended / without a local Chrome session"

# 3. Scoped to UI/frontend changes only
grep -qiE "UI/frontend|frontend" "$BUILD_MJS" \
  || fail "otta-build.mjs does not scope the UI check to frontend changes"

# 4. Explicitly skippable for backend/CLI-only changes
grep -qi "skip for backend" "$BUILD_MJS" \
  || fail "otta-build.mjs does not state the UI check is skippable for backend/CLI-only changes"

echo "✓ build-visual-verify: all 4 checks passed"
