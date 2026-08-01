#!/usr/bin/env bash
# Regression: this repo must not TRACK its own .pr-body.md.
#
# A tracked PR body is shared mutable state on a fixed path. Every branch wants
# different content there, which produces three recurring failures:
#
#   1. merge-train conflicts — GitHub does not run custom merge drivers
#      server-side, so `merge=ours` cannot prevent them on the remote. PRs go
#      DIRTY the moment another PR merges.
#   2. rebase body-swap — locally the driver DOES run, and during a rebase
#      "ours" is the UPSTREAM side. So rebasing silently replaces your branch's
#      body with main's. This happened three times in one session on
#      otta-build/otta-engine; each PR would have shipped describing the wrong
#      change had it not been caught by hand.
#   3. stale bodies surviving merges — a tracked file persists, so a new branch
#      inherits the last merged PR's body instead of a freshly seeded one.
#
# otta-build/dev untracked it in its #78 and stopped hitting all three. This
# brings the plugin to the same shape.
#
# The `merge=ours` driver and install-merge-ours.sh REMAIN supported for
# consumer repos that choose to track their body — that is a per-repo choice,
# and tests/merge-ours-prbody.test.sh still covers it. This test is only about
# what THIS repo does.
# Run: bash plugins/otta/tests/pr-body-untracked.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

fail() { echo "✗ $1" >&2; exit 1; }

cd "$REPO"

# 1. Not tracked in git.
if git ls-files --error-unmatch .pr-body.md >/dev/null 2>&1; then
  fail ".pr-body.md is tracked — untrack it (git rm --cached .pr-body.md)"
fi

# 2. Ignored, so a seeded body never shows up as an untracked file begging to
#    be committed. Without this the working tree looks dirty on every run and
#    someone eventually commits it back.
[ -f "$REPO/.gitignore" ] || fail ".gitignore is missing — .pr-body.md must be ignored"
grep -qx '\.pr-body\.md' "$REPO/.gitignore" \
  || fail ".pr-body.md is not listed in .gitignore"

# 3. Prove the ignore actually applies (a rule can be present but overridden by
#    a later negation).
tmp_body=0
if [ ! -f "$REPO/.pr-body.md" ]; then
  printf 'probe\n' > "$REPO/.pr-body.md"
  tmp_body=1
fi
ignored=0
git check-ignore -q .pr-body.md && ignored=1
[ "$tmp_body" = "1" ] && rm -f "$REPO/.pr-body.md"
[ "$ignored" = "1" ] || fail ".pr-body.md is listed but not actually ignored"

# 4. The merge=ours entry must be gone from THIS repo's .gitattributes — it
#    only protects a tracked body, so leaving it is dead config that
#    install-merge-ours.sh would now skip installing anyway.
if [ -f "$REPO/.gitattributes" ] \
   && grep -qF '.pr-body.md merge=ours' "$REPO/.gitattributes"; then
  fail "dead '.pr-body.md merge=ours' left in .gitattributes"
fi

echo "✓ .pr-body.md is untracked, ignored, and carries no dead merge driver"
