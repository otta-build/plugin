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
# TRACKED .pr-body.md. A repo that untracked the file has chosen the
# untracked-body model instead, where the entry is dead config — git only ever
# applies a merge driver to a tracked path — and appending it would dirty a
# tracked file (.gitattributes) on every seed, leaking a spurious one-line diff
# into unrelated PRs.
#
# "Absent" is NOT opting out: at /otta:setup time the body usually does not
# exist yet, and setup.md documents the driver as always installed. So the
# signals are an explicit .gitignore rule, or a body that exists on disk while
# git does not track it (otta-build/plugin#198 — a repo can untrack without
# adding the ignore rule, and otta-engine's regression test then fails the
# build on the leftover entry).
#
# Resolve both against the repo root: run from a subdirectory, a cwd-relative
# check looks up `sub/.pr-body.md`, misses the rule, and installs anyway.
TOPLEVEL="$(git rev-parse --show-toplevel)"
if git -C "$TOPLEVEL" check-ignore -q .pr-body.md 2>/dev/null; then
  echo "✓ .pr-body.md is gitignored — skipping merge=ours driver (not needed for an untracked body)"
  exit 0
fi
if [ -e "$TOPLEVEL/.pr-body.md" ] \
   && ! git -C "$TOPLEVEL" ls-files --error-unmatch .pr-body.md >/dev/null 2>&1; then
  echo "✓ .pr-body.md is untracked — skipping merge=ours driver (a merge driver only applies to tracked paths)"
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
