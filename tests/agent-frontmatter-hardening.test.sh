#!/usr/bin/env bash
# agent-frontmatter-hardening.test.sh — regression for issue #154 AC(c1).
#
# AC(c1): pipeline agents declare spawn restrictions so review/verify/ship
# stages cannot spawn other pipeline agents (disallowed-tools, since none of
# the 4 agents' `tools:` whitelists include Task/Agent to begin with — this
# makes that restriction explicit and verifiable), and each of the 4 agents
# declares an explicit `effort` appropriate to its stage
# (builder=medium, reviewer=high, qa=high, devops=low).
#
# Run: bash tests/agent-frontmatter-hardening.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$HERE/../agents"

fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

declare -A EXPECTED_EFFORT=(
  [builder]=medium
  [reviewer]=high
  [qa]=high
  [devops]=low
)

for agent in builder reviewer qa devops; do
  f="$AGENTS_DIR/$agent.md"
  [ -f "$f" ] || fail "$agent.md not found at $f"

  grep -qE '^disallowed-tools:.*(Task|Agent)' "$f" \
    || fail "$agent.md missing disallowed-tools spawn restriction (Task/Agent)"
  pass "$agent.md declares disallowed-tools spawn restriction"

  expected="${EXPECTED_EFFORT[$agent]}"
  grep -qE "^effort: *${expected}\$" "$f" \
    || fail "$agent.md missing 'effort: $expected'"
  pass "$agent.md declares effort: $expected"

  # tools: whitelist must not itself list Task/Agent (belt-and-suspenders).
  tools_line="$(grep -E '^tools:' "$f" || true)"
  echo "$tools_line" | grep -qE '\bTask\b|\bAgent\b' \
    && fail "$agent.md tools: whitelist must not include Task/Agent"
done
pass "no agent's tools: whitelist includes Task/Agent"

echo ""
echo "✓ agent-frontmatter-hardening: all checks passed"
