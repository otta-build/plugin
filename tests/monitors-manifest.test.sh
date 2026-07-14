#!/usr/bin/env bash
# monitors-manifest.test.sh — regression for issue #154 AC(e).
#
# AC(e): the plugin declares an opt-in `experimental.monitors` manifest entry
# that watches gate/CI status after ship (Monitor tool, shipped 2.1.105),
# while scripts/otta-deploy-verify.sh polling remains the fallback for
# harnesses without Monitor support — this test does NOT rewrite that script.
#
# Run: bash tests/monitors-manifest.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_JSON="$HERE/../.claude-plugin/plugin.json"
DEPLOY_VERIFY="$HERE/../scripts/otta-deploy-verify.sh"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

[ -f "$PLUGIN_JSON" ]    || fail "plugin.json not found at $PLUGIN_JSON"
[ -f "$DEPLOY_VERIFY" ]  || fail "otta-deploy-verify.sh not found at $DEPLOY_VERIFY"

command -v jq >/dev/null 2>&1 || fail "jq required for this test"

jq -e '.experimental.monitors | type == "array"' "$PLUGIN_JSON" >/dev/null 2>&1 \
  || fail "plugin.json missing experimental.monitors array"
pass "plugin.json declares experimental.monitors"

count="$(jq '.experimental.monitors | length' "$PLUGIN_JSON")"
[ "$count" -ge 1 ] || fail "experimental.monitors is empty"

entry="$(jq -c '.experimental.monitors[0]' "$PLUGIN_JSON")"
echo "$entry" | jq -e '.name and .command and .description' >/dev/null 2>&1 \
  || fail "monitors entry missing required fields (name/command/description)"
pass "monitors entry has name, command, description"

# Opt-in: must NOT arm on every session start ("always").
when="$(echo "$entry" | jq -r '.when // "always"')"
[ "$when" != "always" ] || fail "monitors entry must be opt-in (when != 'always')"
echo "$when" | grep -q "on-skill-invoke" || fail "monitors entry 'when' must gate on skill invocation"
pass "monitors entry is opt-in (when: $when)"

echo "$entry" | jq -r '.description' | grep -qi "fallback\|poll" \
  || fail "monitors entry description must note polling fallback"
pass "monitors entry documents the polling fallback"

# The hand-rolled polling script must be untouched by this AC.
grep -q "poll_blocker" "$DEPLOY_VERIFY" || fail "otta-deploy-verify.sh polling was rewritten/removed"
pass "otta-deploy-verify.sh polling fallback preserved"

echo ""
echo "✓ monitors-manifest: all checks passed"
