#!/usr/bin/env bash
# detect-harnesses.sh [repo-dir]
#
# Detects which AI coding harnesses are configured in the given repo directory
# (defaults to $PWD). Outputs newline-separated harness IDs to stdout:
#   claude_code  — .claude/ directory present (per-repo config)
#   codex        — ~/.codex/config.toml exists (global install marker)
#   gemini       — .gemini/settings.json present (per-repo config)
#   cursor       — .cursor/ directory present (per-repo config)
#
# Exits 0 always, even when no harnesses are found (empty output).
# NOTE: Does NOT use `command -v` — global CLI installs without per-repo
# config are not a reliable signal and cause false positives.
set -euo pipefail

REPO="${1:-.}"

[ -d "${REPO}/.claude" ] && echo "claude_code"

[ -f "${HOME}/.codex/config.toml" ] && echo "codex"

[ -f "${REPO}/.gemini/settings.json" ] && echo "gemini"

[ -d "${REPO}/.cursor" ] && echo "cursor"

exit 0
