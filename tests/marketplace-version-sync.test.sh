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
CODEX_PLUGIN_JSON="$REPO/.codex-plugin/plugin.json"
RELEASE_WORKFLOW="$REPO/.github/workflows/auto-release.yml"

[ -f "$MARKETPLACE" ] || fail "missing .claude-plugin/marketplace.json"
[ -f "$PLUGIN_JSON"  ] || fail "missing .claude-plugin/plugin.json"
[ -f "$CODEX_PLUGIN_JSON" ] || fail "missing .codex-plugin/plugin.json"

# Extract versions via grep+sed (no jq dependency).
MARKETPLACE_VER="$(grep '"version"' "$MARKETPLACE" | head -1 | sed 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/')"
PLUGIN_VER="$(grep '"version"' "$PLUGIN_JSON" | head -1 | sed 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/')"
CODEX_PLUGIN_VER="$(grep '"version"' "$CODEX_PLUGIN_JSON" | head -1 | sed 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/')"

[ -n "$MARKETPLACE_VER" ] || fail "could not parse version from marketplace.json"
[ -n "$PLUGIN_VER"      ] || fail "could not parse version from plugin.json"
[ -n "$CODEX_PLUGIN_VER" ] || fail "could not parse version from Codex plugin.json"

if [ "$MARKETPLACE_VER" != "$PLUGIN_VER" ]; then
  fail "version mismatch: marketplace.json=$MARKETPLACE_VER plugin.json=$PLUGIN_VER — bump marketplace.json to match plugin.json before releasing"
fi

if [ "$CODEX_PLUGIN_VER" != "$PLUGIN_VER" ]; then
  fail "version mismatch: Codex plugin.json=$CODEX_PLUGIN_VER Claude plugin.json=$PLUGIN_VER"
fi

grep -q '\.codex-plugin/plugin\.json' "$RELEASE_WORKFLOW" || \
  fail "auto-release does not bump the Codex plugin manifest"
grep -Eq 'git add .*\.codex-plugin/plugin\.json' "$RELEASE_WORKFLOW" || \
  fail "auto-release does not commit the Codex plugin manifest"

pass "marketplace.json version ($MARKETPLACE_VER) == plugin.json version ($PLUGIN_VER)"
pass "Codex plugin.json version ($CODEX_PLUGIN_VER) == Claude plugin.json version ($PLUGIN_VER)"
pass "auto-release bumps and commits the Codex manifest"

# --- issue #117: marketplace listing polish -------------------------------
command -v jq >/dev/null 2>&1 || fail "jq is required to check marketplace listing fields"

MP_ENTRY='.plugins[0]'

PLUGIN_DISPLAY_NAME="$(jq -r '.displayName // empty' "$PLUGIN_JSON")"
PLUGIN_ICON="$(jq -r '.icon // empty' "$PLUGIN_JSON")"
PLUGIN_EXAMPLE="$(jq -r '.examplePrompt // empty' "$PLUGIN_JSON")"
PLUGIN_HOMEPAGE="$(jq -r '.homepage // empty' "$PLUGIN_JSON")"
PLUGIN_AUTHOR="$(jq -r '.author.name // empty' "$PLUGIN_JSON")"

[ -n "$PLUGIN_DISPLAY_NAME" ] || fail "plugin.json missing displayName"
[ -n "$PLUGIN_ICON" ]         || fail "plugin.json missing icon"
[ -n "$PLUGIN_EXAMPLE" ]      || fail "plugin.json missing examplePrompt"
[ -n "$PLUGIN_HOMEPAGE" ]     || fail "plugin.json missing homepage"
[ -n "$PLUGIN_AUTHOR" ]       || fail "plugin.json missing author.name"

MARKET_CATEGORY="$(jq -r "$MP_ENTRY.category // empty" "$MARKETPLACE")"
MARKET_DISPLAY_NAME="$(jq -r "$MP_ENTRY.displayName // empty" "$MARKETPLACE")"
MARKET_ICON="$(jq -r "$MP_ENTRY.icon // empty" "$MARKETPLACE")"
MARKET_EXAMPLE="$(jq -r "$MP_ENTRY.examplePrompt // empty" "$MARKETPLACE")"
MARKET_HOMEPAGE="$(jq -r "$MP_ENTRY.homepage // empty" "$MARKETPLACE")"

[ "$MARKET_CATEGORY" = "Productivity" ] || fail "marketplace.json plugins[0].category must be \"Productivity\" (got \"$MARKET_CATEGORY\")"
[ "$MARKET_DISPLAY_NAME" = "$PLUGIN_DISPLAY_NAME" ] || fail "marketplace.json displayName must match plugin.json displayName"
[ "$MARKET_ICON" = "$PLUGIN_ICON" ]                 || fail "marketplace.json icon must match plugin.json icon"
[ "$MARKET_EXAMPLE" = "$PLUGIN_EXAMPLE" ]           || fail "marketplace.json examplePrompt must match plugin.json examplePrompt"
[ "$MARKET_HOMEPAGE" = "$PLUGIN_HOMEPAGE" ]         || fail "marketplace.json homepage must match plugin.json homepage"

CODEX_ICON="$(jq -r '.icon // empty' "$CODEX_PLUGIN_JSON")"
CODEX_EXAMPLE="$(jq -r '.examplePrompt // empty' "$CODEX_PLUGIN_JSON")"
[ "$CODEX_ICON" = "$PLUGIN_ICON" ]       || fail "Codex plugin.json icon must mirror Claude plugin.json icon"
[ "$CODEX_EXAMPLE" = "$PLUGIN_EXAMPLE" ] || fail "Codex plugin.json examplePrompt must mirror Claude plugin.json examplePrompt"

pass "plugin.json carries displayName, icon, examplePrompt, homepage, author.name"
pass "marketplace.json plugins[0] carries category=Productivity and mirrors displayName/icon/examplePrompt/homepage"
pass "Codex plugin.json mirrors icon and examplePrompt"

if command -v claude >/dev/null 2>&1; then
  if claude plugin validate "$REPO" >/tmp/otta-plugin-validate.$$ 2>&1; then
    pass "claude plugin validate: no load-breaking errors (unknown fields degrade gracefully)"
  else
    cat /tmp/otta-plugin-validate.$$ >&2
    fail "claude plugin validate reported a load-breaking error"
  fi
  rm -f /tmp/otta-plugin-validate.$$
else
  pass "claude CLI not on PATH — skipping claude plugin validate (non-blocking)"
fi

echo ""
echo "✓ marketplace-version-sync: all checks passed"
