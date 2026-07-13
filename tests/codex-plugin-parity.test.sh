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

canonical_commands=(
  setup start dev build fix ship status schedule remember pulse-doctor
)
portable_command_root='${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}'

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

expected_otta_skill_dirs="$(printf 'otta-%s\n' "${canonical_commands[@]}" | sort)"
actual_otta_skill_dirs="$(
  find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d -name 'otta-*' -exec basename {} \; | sort
)"
if [ "$actual_otta_skill_dirs" = "$expected_otta_skill_dirs" ]; then
  pass "Codex exposes exactly the ten canonical otta-* skill directories"
else
  fail "Codex otta-* skill directories must match the ten canonical commands (found: $(printf '%s' "$actual_otta_skill_dirs" | tr '\n' ' '))"
fi

for command_name in "${canonical_commands[@]}"; do
  skill="$REPO/skills/otta-$command_name/SKILL.md"
  command_doc="$REPO/commands/$command_name.md"

  if [ ! -f "$skill" ]; then
    fail "missing Codex skill skills/otta-$command_name/SKILL.md"
  else
    frontmatter="$(awk '
      NR == 1 && $0 == "---" { in_frontmatter=1; next }
      in_frontmatter && $0 == "---" { exit }
      in_frontmatter { print }
    ' "$skill")"

    if [ "$(sed -n '1p' "$skill")" = "---" ] &&
       [ "$(sed -n '4p' "$skill")" = "---" ] &&
       printf '%s\n' "$frontmatter" | grep -qx "name: otta-$command_name" &&
       printf '%s\n' "$frontmatter" | grep -Eq '^description: .+' &&
       [ "$(printf '%s\n' "$frontmatter" | grep -Ec '^[a-zA-Z0-9_-]+: .+$')" -eq 2 ]; then
      pass "otta-$command_name has valid, uniquely named YAML frontmatter"
    else
      fail "otta-$command_name must have valid YAML frontmatter with name: otta-$command_name and a description"
    fi

    canonical_reference="../../commands/$command_name.md"
    bootstrap_line="$(grep -nF 'retain that absolute path as `OTTA_PLUGIN_ROOT` in this skill execution state' "$skill" | cut -d: -f1 || true)"
    invocation_line="$(grep -nF "inline-prefix \`OTTA_PLUGIN_ROOT='<resolved absolute root>'\`" "$skill" | cut -d: -f1 || true)"
    canonical_line="$(grep -nF "$canonical_reference" "$skill" | cut -d: -f1 || true)"
    if grep -Fq 'loaded `SKILL.md` resource path' "$skill" &&
       grep -Fq 'two directories above this skill directory' "$skill" &&
       grep -Fq 'Reject an empty resolved root.' "$skill" &&
       grep -Fq 'verify its referenced Bash target is a readable regular file' "$skill" &&
       grep -Fq 'verify each structured-tool target exists and is readable' "$skill" &&
       grep -Fq 'substitute the absolute root directly into every plugin path or root argument' "$skill" &&
       grep -Fq 'Do not rely on exported environment persistence between tool calls.' "$skill" &&
       grep -Fq 'Never assume `PLUGIN_ROOT` exists outside hook execution.' "$skill" &&
       ! grep -Fq 'export it as `OTTA_PLUGIN_ROOT`' "$skill" &&
       [ -n "$bootstrap_line" ] && [ -n "$invocation_line" ] && [ -n "$canonical_line" ] &&
       [ "$bootstrap_line" -le "$invocation_line" ] && [ "$invocation_line" -lt "$canonical_line" ]; then
      pass "otta-$command_name retains its loaded-path root and injects it into every guarded invocation"
    else
      fail "otta-$command_name must retain its loaded-path root as skill state and inject OTTA_PLUGIN_ROOT into every guarded invocation without relying on export persistence"
    fi

    if grep -q '^argument-hint:' "$command_doc"; then
      if grep -Fq 'Bind the first Codex invocation argument to canonical `$1` and the full argument string to `$ARGUMENTS`; preserve an absent optional first argument as empty.' "$skill"; then
        pass "otta-$command_name binds Codex invocation arguments to canonical command variables"
      else
        fail "otta-$command_name must bind Codex invocation arguments explicitly to canonical \$1/\$ARGUMENTS"
      fi
    fi

    markdown_targets="$(
      grep -Eo '\(\.\./\.\./commands/[^()[:space:]]+\)' "$skill" |
        sed 's/^(\(.*\))$/\1/' || true
    )"
    if [ "$markdown_targets" = "$canonical_reference" ] &&
       [ -f "$(dirname "$skill")/$markdown_targets" ] &&
       grep -Eiq 'read.{0,40}(and )?follow|follow.{0,40}canonical' "$skill"; then
      pass "otta-$command_name delegates to its exact, resolvable canonical command workflow"
    else
      fail "otta-$command_name must have exactly one resolvable Markdown target: $canonical_reference"
    fi

    if grep -Fq 'In Codex context, invoke Otta skills as `$otta-<name>`; do not invoke Claude command syntax `/otta:<name>`.' "$skill"; then
      pass "otta-$command_name maps internal command references to Codex skill syntax"
    else
      fail "otta-$command_name must map canonical /otta:<name> references to Codex-native \$otta-<name> skill syntax"
    fi
  fi

  if grep -Fn '${CLAUDE_PLUGIN_ROOT}' "$command_doc" >/dev/null; then
    while IFS= read -r occurrence; do
      fail "commands/$command_name.md has nonportable executable path: $occurrence"
    done < <(grep -Fn '${CLAUDE_PLUGIN_ROOT}' "$command_doc")
  else
    pass "commands/$command_name.md has no bare CLAUDE_PLUGIN_ROOT executable paths"
  fi

  root_reference_count="$(grep -Fo '${CLAUDE_PLUGIN_ROOT' "$command_doc" | wc -l | tr -d ' ')"
  portable_root_count="$(grep -Fo "$portable_command_root" "$command_doc" | wc -l | tr -d ' ')"
  nonportable_path_lines="$(
    grep -En '\$\{.*\}/(scripts|workflows)/' "$command_doc" |
      grep -Fv "$portable_command_root" || true
  )"
  if [ "$root_reference_count" -eq "$portable_root_count" ] &&
     [ -z "$nonportable_path_lines" ]; then
    pass "commands/$command_name.md gives OTTA_PLUGIN_ROOT precedence for every executable plugin path"
  else
    fail "commands/$command_name.md must use $portable_command_root for every executable plugin path"
  fi
done

BUILD_COMMAND="$REPO/commands/build.md"
if grep -Fq 'When the `Workflow` tool is available' "$BUILD_COMMAND" &&
   grep -Fq 'When `Workflow` is unavailable' "$BUILD_COMMAND" &&
   grep -Fq '`spawn_agent`' "$BUILD_COMMAND" &&
   grep -Fq '`wait_agent`' "$BUILD_COMMAND" &&
   grep -Fq '`send_message` or `followup_task`' "$BUILD_COMMAND" &&
   grep -Fq 'builder → reviewer → qa → devops' "$BUILD_COMMAND" &&
   grep -Fq 'include the resolved absolute plugin root in every subagent prompt' "$BUILD_COMMAND" &&
   grep -Fq 'inline-inject `OTTA_PLUGIN_ROOT` for every plugin command' "$BUILD_COMMAND" &&
   grep -Fq 'If neither Workflow nor collaboration/subagent primitives are available' "$BUILD_COMMAND"; then
  pass "build preserves Workflow and defines sequential Codex-native orchestration"
else
  fail "build must conditionally preserve Workflow and define sequential Codex spawn/wait/feedback orchestration"
fi

DEV_COMMAND="$REPO/commands/dev.md"
if grep -Fq 'Codex subagent mapping' "$DEV_COMMAND" &&
   grep -Fq '`spawn_agent`' "$DEV_COMMAND" &&
   grep -Fq '`wait_agent`' "$DEV_COMMAND" &&
   grep -Fq '`send_message` or `followup_task`' "$DEV_COMMAND" &&
   grep -Fq 'agents/<role>.md' "$DEV_COMMAND" &&
   grep -Fq 'include the resolved absolute plugin root in every subagent prompt' "$DEV_COMMAND" &&
   grep -Fq 'If collaboration/subagent primitives are unavailable' "$DEV_COMMAND"; then
  pass "dev maps role dispatch to Codex-native subagent primitives"
else
  fail "dev must map Task/Agent role dispatch to Codex spawn/wait/feedback primitives"
fi

SCHEDULE_COMMAND="$REPO/commands/schedule.md"
if grep -Fq 'Claude Code with the `/schedule` skill' "$SCHEDULE_COMMAND" &&
   grep -Fq 'Codex does not provide a persistent cloud scheduler through this plugin.' "$SCHEDULE_COMMAND" &&
   grep -Fq 'copy-ready routine prompt' "$SCHEDULE_COMMAND" &&
   grep -Fq 'Do not claim that a schedule was saved' "$SCHEDULE_COMMAND"; then
  pass "schedule documents a truthful Codex fallback"
else
  fail "schedule must keep Claude routines while giving Codex a truthful graceful alternative"
fi

SHIPPING_LOOP_SKILL="$REPO/skills/shipping-loop/SKILL.md"
if grep -Fq 'Claude Code: `/otta:start`; Codex: `$otta-start`.' "$SHIPPING_LOOP_SKILL" &&
   grep -Fq 'Claude Code: `/otta:ship`; Codex: `$otta-ship`.' "$SHIPPING_LOOP_SKILL" &&
   grep -Fq 'Claude Code: `/otta:setup`; Codex: `$otta-setup`.' "$SHIPPING_LOOP_SKILL"; then
  pass "shipping-loop maps commands across Claude and Codex runtimes"
else
  fail "shipping-loop must describe equivalent Claude slash commands and Codex skills"
fi

for role in builder reviewer qa devops; do
  agent_doc="$REPO/agents/$role.md"
  agent_root_refs="$(grep -Fo '${CLAUDE_PLUGIN_ROOT' "$agent_doc" | wc -l | tr -d ' ')"
  agent_portable_refs="$(grep -Fo "$portable_command_root" "$agent_doc" | wc -l | tr -d ' ')"
  if [ "$agent_root_refs" -eq "$agent_portable_refs" ]; then
    pass "agents/$role.md gives OTTA_PLUGIN_ROOT precedence"
  else
    fail "agents/$role.md must use $portable_command_root for every plugin path"
  fi
done

SETUP_COMMAND="$REPO/commands/setup.md"
if grep -Fq '`request_user_input` when available' "$SETUP_COMMAND" &&
   grep -Fq 'ask one concise direct question in chat and wait for the answer' "$SETUP_COMMAND" &&
   grep -Fq 'Do not call an unavailable Claude-only `AskUserQuestion` tool.' "$SETUP_COMMAND" &&
   grep -Fq -- '--derive' "$SETUP_COMMAND"; then
  pass "setup maps interactive questions portably and preserves Codex derive setup"
else
  fail "setup must map AskUserQuestion to available interactive input or direct questions without losing --derive"
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

INSTALLED_FAKE="$TMPDIR/installed-plugin"
OTTA_ONLY_MARKER="$TMPDIR/otta-only.marker"
mkdir -p "$INSTALLED_FAKE/scripts" "$INSTALLED_FAKE/skills/otta-start"
cp "$REPO/skills/otta-start/SKILL.md" "$INSTALLED_FAKE/skills/otta-start/SKILL.md"
cat > "$INSTALLED_FAKE/scripts/root-probe.sh" <<'EOF'
#!/usr/bin/env bash
printf 'installed-plugin-script:%s:%s\n' "$1" "$ARGUMENTS" > "$MARKER"
EOF
chmod 0644 "$INSTALLED_FAKE/scripts/root-probe.sh"
env -i PATH="$PATH" bash -c '
  loaded_skill="$1"
  marker="$2"
  codex_arguments="$3"
  [ -z "${OTTA_PLUGIN_ROOT:-}" ] && [ -z "${PLUGIN_ROOT:-}" ] && [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] || exit 20
  resolved_root="$(cd "$(dirname "$loaded_skill")/../.." && pwd -P)"
  target="$resolved_root/scripts/root-probe.sh"
  [ -n "$resolved_root" ] && [ -f "$target" ] && [ -r "$target" ] || exit 21
  canonical_1="${codex_arguments%% *}"
  OTTA_PLUGIN_ROOT="$resolved_root" MARKER="$marker" ARGUMENTS="$codex_arguments" \
    bash -c '\''bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/root-probe.sh" "$1"'\'' _ "$canonical_1"
' _ "$INSTALLED_FAKE/skills/otta-start/SKILL.md" "$OTTA_ONLY_MARKER" '131 --force' \
  >/dev/null 2>&1 || true
if [ "$(cat "$OTTA_ONLY_MARKER" 2>/dev/null || true)" = "installed-plugin-script:131:131 --force" ]; then
  pass "installed skill path runs a readable Bash target with inline root and canonical argument binding"
else
  fail "installed skill path must resolve and execute its target without persistent runtime root variables"
fi

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
