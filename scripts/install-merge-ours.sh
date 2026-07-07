#!/usr/bin/env bash
# install-merge-ours.sh
#
# Installs the git merge=ours driver for .pr-body.md so every merge from main
# (squash or otherwise) keeps the branch's own PR body instead of conflicting.
#
# What it does (idempotent — safe to run multiple times):
#   1. git config merge.ours.driver true  (repo-local)
#   2. append '.pr-body.md merge=ours' to .gitattributes (no-dup guard)
#
# Usage: bash scripts/install-merge-ours.sh
set -euo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "ERROR: not inside a git repo" >&2; exit 1; }

# 1. Register the merge driver (repo-local config).
git config merge.ours.driver true
echo "✓ git config merge.ours.driver = true"

# 2. Append the gitattributes entry — only if not already present.
ATTR_FILE=".gitattributes"
ENTRY=".pr-body.md merge=ours"

if grep -qF "$ENTRY" "$ATTR_FILE" 2>/dev/null; then
  echo "✓ .gitattributes already contains: $ENTRY (skipped)"
else
  printf '%s\n' "$ENTRY" >> "$ATTR_FILE"
  echo "✓ appended to .gitattributes: $ENTRY"
fi
