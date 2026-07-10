#!/usr/bin/env bash
# marketplace-version-sync.test.sh — asserts .claude-plugin/marketplace.json
# version matches .claude-plugin/plugin.json version (issue #71).
# Run: bash tests/marketplace-version-sync.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

MARKETPLACE="$REPO/.claude-plugin/marketplace.json"
PLUGIN_JSON="$REPO/.claude-plugin/plugin.json"

[ -f "$MARKETPLACE" ] || fail "missing .claude-plugin/marketplace.json"
[ -f "$PLUGIN_JSON"  ] || fail "missing .claude-plugin/plugin.json"

# Extract versions via grep+sed (no jq dependency).
MARKETPLACE_VER="$(grep '"version"' "$MARKETPLACE" | head -1 | sed 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/')"
PLUGIN_VER="$(grep '"version"' "$PLUGIN_JSON" | head -1 | sed 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/')"

[ -n "$MARKETPLACE_VER" ] || fail "could not parse version from marketplace.json"
[ -n "$PLUGIN_VER"      ] || fail "could not parse version from plugin.json"

if [ "$MARKETPLACE_VER" != "$PLUGIN_VER" ]; then
  fail "version mismatch: marketplace.json=$MARKETPLACE_VER plugin.json=$PLUGIN_VER — bump marketplace.json to match plugin.json before releasing"
fi

pass "marketplace.json version ($MARKETPLACE_VER) == plugin.json version ($PLUGIN_VER)"
echo ""
echo "✓ marketplace-version-sync: all checks passed"
