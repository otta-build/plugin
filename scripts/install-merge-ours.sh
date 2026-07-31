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

# 0. Opt-out: this whole driver exists to stop merge-train conflicts on a
# TRACKED .pr-body.md. A repo that gitignores the file has chosen the
# untracked-body model instead, where the entry is dead config — and appending
# it would dirty a tracked file (.gitattributes) on every seed, leaking a
# spurious one-line diff into unrelated PRs.
#
# The signal is "gitignored", not "untracked" or "absent": at /otta:setup time
# the body normally does not exist yet, and setup.md documents the driver as
# always installed. Only an explicit .gitignore entry means opting out.
if git check-ignore -q .pr-body.md 2>/dev/null; then
  echo "✓ .pr-body.md is gitignored — skipping merge=ours driver (not needed for an untracked body)"
  exit 0
fi

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
