#!/usr/bin/env bash
# subagent-gate-guard.sh — SubagentStop hook.
#
# When an Otta *build* subagent finishes, run the Otta gate. If it fails, block
# the stop (exit 2) and write the reasons to stderr — Claude Code feeds that back
# to the subagent so it keeps working instead of reporting a false "done".
# A build stage literally cannot finish past a failing gate.
#
# Reads the SubagentStop JSON on stdin: { agent_type, agent_id, cwd, ... }.
# Scope: only the builder stage. The reviewer is read-only; qa already runs the
# gate itself; devops opens the PR after the gate has already passed.
#
# Guards (so it never fires at the wrong time):
#   - non-builder agent_type            → exit 0 (skip)
#   - no .pr-body.md in the repo         → exit 0 (repo not in the Otta loop)
#   - OTTA_SKIP_GATE=1                    → exit 0 (explicit bypass)
# Loop safety: Claude Code ends the turn after 8 consecutive blocking stops
# (override CLAUDE_CODE_STOP_HOOK_BLOCK_CAP). There is no per-hook re-entry flag,
# so the .pr-body.md guard + a genuinely-passable gate are what bound the loop.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"

[ -n "${OTTA_SKIP_GATE:-}" ] && exit 0

# --- parse the SubagentStop payload ---------------------------------------
if command -v jq >/dev/null 2>&1; then
  agent_type="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null)"
  agent_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
else
  agent_type="$(printf '%s' "$input" | grep -o '"agent_type"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
  agent_cwd="$(printf '%s' "$input" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
fi

# Only the builder stage (matches "otta:builder" or a bare "builder").
case "$agent_type" in
  *builder) ;;
  *) exit 0 ;;
esac

# Run in the subagent's working dir (the worktree, for /otta:start) when given.
if [ -n "$agent_cwd" ] && [ -d "$agent_cwd" ]; then
  cd "$agent_cwd" 2>/dev/null || true
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  cd "$CLAUDE_PROJECT_DIR" 2>/dev/null || true
fi

# Only gate a repo that is actually in the loop (has a seeded body).
[ -f ".pr-body.md" ] || exit 0

# Run the full gate. Capture stdout+stderr so the failing-check detail (not just
# the final verdict) is fed back to the builder. The gate also writes its verdict
# to the LEARN ledger on every run — so each build-stage check is captured too.
if ! out="$(bash "$HERE/../scripts/otta-gate.sh" 2>&1)"; then
  {
    echo "⛔ Otta gate failed at the build stage — do not finish until it passes:"
    echo "$out"
    echo ""
    echo "Fix the issues above and continue. (Bypass for this run: OTTA_SKIP_GATE=1.)"
  } >&2
  exit 2
fi
exit 0
