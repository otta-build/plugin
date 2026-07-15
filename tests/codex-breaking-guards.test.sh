#!/usr/bin/env bash
# codex-breaking-guards.test.sh — regression for issue #157 AC(g5).
#
# AC(g5): regression guards for upstream Codex breaking changes:
#   (i)   no reliance on removed file-based custom prompts
#         (no ~/.codex/prompts references; .codex-plugin/plugin.json
#         retains the `skills` pointer)
#   (ii)  no use of removed/renamed agent tool names (close_agent,
#         assign_task) anywhere in commands/skills/agents
#   (iii) hooks/hooks.json top-level keys restricted to the supported set
#
# Run: bash tests/codex-breaking-guards.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
MANIFEST="$REPO/.codex-plugin/plugin.json"
HOOKS="$REPO/hooks/hooks.json"
failures=0

fail() { echo "✗ FAIL: $1" >&2; failures=$((failures + 1)); }
pass() { echo "  ✓ $1"; }

# (i) no reliance on removed file-based custom prompts (~/.codex/prompts).
# Scan documentation/config surfaces only; exclude this test file itself and
# .pr-body.md, which legitimately quotes the guarded string as AC text.
prompt_hits="$(
  grep -rlF '~/.codex/prompts' "$REPO/commands" "$REPO/skills" "$REPO/agents" \
    "$REPO/scripts" "$REPO/docs" 2>/dev/null || true
)"
if [ -z "$prompt_hits" ]; then
  pass "no ~/.codex/prompts references in commands/skills/agents/scripts/docs"
else
  fail "removed ~/.codex/prompts referenced in: $(printf '%s' "$prompt_hits" | tr '\n' ' ')"
fi

if [ -f "$MANIFEST" ] && jq -e '.skills == "./skills/"' "$MANIFEST" >/dev/null 2>&1; then
  pass ".codex-plugin/plugin.json retains the skills pointer"
else
  fail ".codex-plugin/plugin.json must retain the skills pointer"
fi

# (ii) no removed/renamed agent tool names.
for removed_tool in close_agent assign_task; do
  tool_hits="$(
    grep -rlF "$removed_tool" "$REPO/commands" "$REPO/skills" "$REPO/agents" 2>/dev/null || true
  )"
  if [ -z "$tool_hits" ]; then
    pass "no use of removed/renamed tool name '$removed_tool' in commands/skills/agents"
  else
    fail "removed/renamed tool '$removed_tool' referenced in: $(printf '%s' "$tool_hits" | tr '\n' ' ')"
  fi
done

# (iii) hooks/hooks.json top-level keys restricted to the supported set.
supported_top_level_keys="hooks"
if [ -f "$HOOKS" ]; then
  actual_keys="$(jq -r 'keys[]' "$HOOKS" 2>/dev/null | sort)"
  expected_keys="$(printf '%s\n' $supported_top_level_keys | sort)"
  if [ "$actual_keys" = "$expected_keys" ]; then
    pass "hooks/hooks.json top-level keys restricted to the supported set ($supported_top_level_keys)"
  else
    fail "hooks/hooks.json top-level keys must be exactly {$supported_top_level_keys}, found: $(printf '%s' "$actual_keys" | tr '\n' ' ')"
  fi
else
  fail "hooks/hooks.json not found at $HOOKS"
fi

if [ "$failures" -ne 0 ]; then
  echo "" >&2
  echo "✗ codex-breaking-guards: $failures check(s) failed" >&2
  exit 1
fi

echo ""
echo "✓ codex-breaking-guards: all checks passed"
