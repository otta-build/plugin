#!/usr/bin/env bash
# hooks-harness-split.test.sh — regression for issue #155.
#
# hooks/hooks.codex.json (Codex, shell-string `command` form via `bash -c`)
# and hooks/hooks.claude.json (Claude Code, exec `args` array form, CC
# 2.1.207+ injection-hardening direction) must declare the same hook
# events, the same matchers per event, and target the same scripts, so the
# two harnesses can never silently drift even though their command forms
# differ.
#
# The hooks files live under separate filenames — NOT hooks/hooks.json —
# because Claude Code's "own merge rules" for the `hooks` manifest field
# (see plugins-reference.md) load the conventional ./hooks/hooks.json path
# ADDITIVELY alongside any explicit `hooks` key in plugin.json, rather than
# the explicit key replacing it. A prior version of this split kept the
# Codex file at the conventional hooks/hooks.json path while also pointing
# .claude-plugin/plugin.json at hooks.claude.json via an explicit key — CC
# then loaded BOTH files, double-firing every hook. Renaming the Codex file
# off the conventional path empties it, so CC's conventional-path scan
# finds nothing there and only the explicit hooks.claude.json loads. Codex,
# by contrast, replaces its default hooks/hooks.json discovery whenever
# .codex-plugin/plugin.json declares an explicit `hooks` entry, so pointing
# it at hooks.codex.json is safe on that side without a rename-driven
# workaround.
#
# See also tests/hooks-shell-injection-guard.test.sh (${user_config.*}
# guard) and tests/codex-plugin-parity.test.sh (Codex manifest contract).
#
# Run: bash tests/hooks-harness-split.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
CODEX_MANIFEST="$REPO/.codex-plugin/plugin.json"
CLAUDE_MANIFEST="$REPO/.claude-plugin/plugin.json"
CODEX_HOOKS="$REPO/hooks/hooks.codex.json"
CLAUDE_HOOKS="$REPO/hooks/hooks.claude.json"
CONVENTIONAL_HOOKS="$REPO/hooks/hooks.json"
failures=0

fail() { echo "✗ FAIL: $1" >&2; failures=$((failures + 1)); }
pass() { echo "  ✓ $1"; }

for f in "$CODEX_MANIFEST" "$CLAUDE_MANIFEST" "$CODEX_HOOKS" "$CLAUDE_HOOKS"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

# Regression guard: the conventional ./hooks/hooks.json path must stay
# empty. If anything ever recreates it, Claude Code's additive merge rules
# for the `hooks` manifest field would double-fire every hook alongside
# hooks.claude.json (see comment header).
if [ -f "$CONVENTIONAL_HOOKS" ]; then
  fail "hooks/hooks.json must not exist — it double-fires with hooks.claude.json under CC's additive hooks merge rules (rename target: hooks.codex.json for Codex, hooks.claude.json for Claude Code)"
else
  pass "hooks/hooks.json (conventional path) does not exist — no double-fire risk"
fi

if [ "$failures" -eq 0 ]; then
  # AC1: manifests point at their own hooks file.
  if jq -e '.hooks == "./hooks/hooks.codex.json"' "$CODEX_MANIFEST" >/dev/null; then
    pass "Codex manifest declares hooks: ./hooks/hooks.codex.json"
  else
    fail 'Codex manifest must declare "hooks": "./hooks/hooks.codex.json"'
  fi

  if jq -e '.hooks == "./hooks/hooks.claude.json"' "$CLAUDE_MANIFEST" >/dev/null; then
    pass "Claude Code manifest declares hooks: ./hooks/hooks.claude.json"
  else
    fail 'Claude Code manifest must declare "hooks": "./hooks/hooks.claude.json"'
  fi

  # AC2: hooks.claude.json is exec args-form only — no shell-string commands.
  # Every hook entry's "command" value must be a bare executable name (no
  # spaces, no quotes, no ${...} expansion) and every entry must carry an
  # "args" array.
  bare_command_count="$(jq '[.hooks[][].hooks[].command | select(test(" ") or test("\\$\\{"))] | length' "$CLAUDE_HOOKS")"
  if [ "$bare_command_count" = "0" ]; then
    pass "hooks.claude.json has no shell-string command values (bare executables only)"
  else
    fail "hooks.claude.json must use bare executable command values (found $bare_command_count shell-string-looking command(s))"
  fi

  missing_args_count="$(jq '[.hooks[][].hooks[] | select(has("args") | not)] | length' "$CLAUDE_HOOKS")"
  if [ "$missing_args_count" = "0" ]; then
    pass "hooks.claude.json entries all use exec args-array form"
  else
    fail "hooks.claude.json has $missing_args_count entr(y/ies) missing the args array (shell form leaked in)"
  fi

  # AC3: no ${user_config.*} anywhere in either hooks file.
  if grep -F '${user_config.' "$CLAUDE_HOOKS" >/dev/null 2>&1; then
    fail "hooks.claude.json contains \${user_config.*} interpolation"
  else
    pass "hooks.claude.json contains no \${user_config.*} interpolation"
  fi

  # Semantic equivalence: same hook events, same matchers per event, and
  # same target scripts (basename), across both manifests — so they cannot
  # drift silently.
  codex_events="$(jq -r '.hooks | keys[]' "$CODEX_HOOKS" | sort)"
  claude_events="$(jq -r '.hooks | keys[]' "$CLAUDE_HOOKS" | sort)"
  if [ "$codex_events" = "$claude_events" ]; then
    pass "hooks.codex.json and hooks.claude.json declare the same hook events"
  else
    fail "hook events differ between hooks.codex.json ($codex_events) and hooks.claude.json ($claude_events)"
  fi

  codex_matchers="$(jq -r '.hooks | to_entries[] | "\(.key)=\([.value[].matcher] | sort | join(","))"' "$CODEX_HOOKS" | sort)"
  claude_matchers="$(jq -r '.hooks | to_entries[] | "\(.key)=\([.value[].matcher] | sort | join(","))"' "$CLAUDE_HOOKS" | sort)"
  if [ "$codex_matchers" = "$claude_matchers" ]; then
    pass "hooks.codex.json and hooks.claude.json declare the same matchers per event ($(echo "$codex_matchers" | tr '\n' ' '))"
  else
    fail "matchers differ between hooks.codex.json ($codex_matchers) and hooks.claude.json ($claude_matchers)"
  fi

  codex_scripts="$(jq -r '.hooks[][].hooks[].command' "$CODEX_HOOKS" | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u)"
  claude_scripts="$(jq -r '.hooks[][].hooks[].args[]?' "$CLAUDE_HOOKS" | grep -oE '[A-Za-z0-9_-]+\.sh' | sort -u)"
  if [ "$codex_scripts" = "$claude_scripts" ] && [ -n "$codex_scripts" ]; then
    pass "hooks.codex.json and hooks.claude.json target the same scripts ($(echo "$codex_scripts" | tr '\n' ' '))"
  else
    fail "target scripts differ between hooks.codex.json ($codex_scripts) and hooks.claude.json ($claude_scripts)"
  fi
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✓ hooks-harness-split: all checks passed"
  exit 0
else
  echo "✗ hooks-harness-split: $failures failure(s)"
  exit 1
fi
