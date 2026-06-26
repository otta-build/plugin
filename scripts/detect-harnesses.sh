#!/usr/bin/env bash
# detect-harnesses.sh [repo-dir]
#
# Detects which AI coding harnesses are configured in the given repo directory
# (defaults to $PWD). Outputs newline-separated harness IDs to stdout:
#   claude_code  — .claude/ directory present
#   codex        — `codex` CLI in PATH or ~/.codex/config.toml exists
#   gemini       — `gemini` CLI in PATH or .gemini/settings.json present
#   cursor       — .cursor/ directory present or `cursor` CLI in PATH
#
# Exits 0 always, even when no harnesses are found (empty output).
set -euo pipefail

REPO="${1:-.}"

[ -d "${REPO}/.claude" ] && echo "claude_code"

if command -v codex >/dev/null 2>&1 || [ -f "${HOME}/.codex/config.toml" ]; then
  echo "codex"
fi

if command -v gemini >/dev/null 2>&1 || [ -f "${REPO}/.gemini/settings.json" ]; then
  echo "gemini"
fi

if [ -d "${REPO}/.cursor" ] || command -v cursor >/dev/null 2>&1; then
  echo "cursor"
fi

exit 0
