#!/usr/bin/env bash
# codex-plugin-parity.test.sh — Codex manifest and dual-runtime hook contract.
# Run: bash tests/codex-plugin-parity.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
MANIFEST="$REPO/.codex-plugin/plugin.json"
HOOKS="$REPO/hooks/hooks.json"
failures=0

fail() {
  echo "✗ FAIL: $1" >&2
  failures=$((failures + 1))
}

pass() {
  echo "  ✓ $1"
}

if [ ! -f "$MANIFEST" ]; then
  fail "missing .codex-plugin/plugin.json"
else
  if jq -e '.skills == "./skills/"' "$MANIFEST" >/dev/null; then
    pass "Codex manifest declares skills path"
  else
    fail 'Codex manifest must declare "skills": "./skills/"'
  fi

  if jq -e '.hooks == "./hooks/hooks.json"' "$MANIFEST" >/dev/null; then
    pass "Codex manifest declares hooks path"
  else
    fail 'Codex manifest must declare "hooks": "./hooks/hooks.json"'
  fi
fi

expected_command() {
  case "$1" in
    PreToolUse) echo 'bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/pre-push-guard.sh"' ;;
    SubagentStop) echo 'bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/subagent-gate-guard.sh"' ;;
  esac
}

expected_target() {
  case "$1" in
    PreToolUse) echo "pre-push" ;;
    SubagentStop) echo "subagent" ;;
  esac
}

for hook_name in PreToolUse SubagentStop; do
  command="$(jq -r --arg hook "$hook_name" '.hooks[$hook][0].hooks[0].command // ""' "$HOOKS")"
  if [ "$command" = "$(expected_command "$hook_name")" ]; then
    pass "$hook_name uses the exact dual-runtime command"
  else
    fail "$hook_name command must equal $(expected_command "$hook_name")"
  fi
done

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

make_fake_root() {
  root="$1"
  label="$2"
  mkdir -p "$root/hooks"
  for hook_target in pre-push subagent; do
    if [ "$hook_target" = pre-push ]; then
      hook_script="pre-push-guard.sh"
    else
      hook_script="subagent-gate-guard.sh"
    fi
    cat > "$root/hooks/$hook_script" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$label:$hook_target' > "\$MARKER"
EOF
    chmod +x "$root/hooks/$hook_script"
  done
}

PLUGIN_FAKE="$TMPDIR/plugin-root"
CLAUDE_FAKE="$TMPDIR/claude-root"
CODEX_DECOY="$TMPDIR/codex-root"
make_fake_root "$PLUGIN_FAKE" "plugin"
make_fake_root "$CLAUDE_FAKE" "claude"
make_fake_root "$CODEX_DECOY" "codex-decoy"

for hook_name in PreToolUse SubagentStop; do
  command="$(jq -r --arg hook "$hook_name" '.hooks[$hook][0].hooks[0].command // ""' "$HOOKS")"
  target="$(expected_target "$hook_name")"

  for runtime in plugin claude; do
    marker="$TMPDIR/$hook_name-$runtime.marker"
    if [ "$runtime" = plugin ]; then
      env -i PATH="$PATH" MARKER="$marker" PLUGIN_ROOT="$PLUGIN_FAKE" \
        CODEX_PLUGIN_ROOT="$CODEX_DECOY" bash -c "$command" >/dev/null 2>&1 || true
    else
      env -i PATH="$PATH" MARKER="$marker" CLAUDE_PLUGIN_ROOT="$CLAUDE_FAKE" \
        CODEX_PLUGIN_ROOT="$CODEX_DECOY" bash -c "$command" >/dev/null 2>&1 || true
    fi

    actual="$(cat "$marker" 2>/dev/null || true)"
    if [ "$actual" = "$runtime:$target" ]; then
      pass "$hook_name executes the $runtime root $target target"
    else
      fail "$hook_name with $runtime root executed '${actual:-nothing}', expected $runtime:$target"
    fi
  done
done

if [ "$failures" -ne 0 ]; then
  echo "" >&2
  echo "✗ codex-plugin-parity: $failures check(s) failed" >&2
  exit 1
fi

echo ""
echo "✓ codex-plugin-parity: all checks passed"
