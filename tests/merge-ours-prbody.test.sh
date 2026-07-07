#!/usr/bin/env bash
# merge-ours-prbody.test.sh — tests for scripts/install-merge-ours.sh (issue #96)
# Verifies: driver install, gitattributes entry, idempotency, merge keeps branch content.
# Run: bash tests/merge-ours-prbody.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/install-merge-ours.sh"

fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

[ -f "$SCRIPT" ] || fail "install-merge-ours.sh not found at $SCRIPT"

# ---------------------------------------------------------------------------
# Helpers: set up a minimal bare git repo in a tmpdir
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
}

# ---------------------------------------------------------------------------
# Test 1: installs merge.ours.driver = true in the repo's git config
# ---------------------------------------------------------------------------
R1="$TMP/r1"
make_repo "$R1"
# need at least one commit so git config local works
echo init > "$R1/x.txt"
git -C "$R1" add x.txt
git -C "$R1" commit -qm init

(cd "$R1" && bash "$SCRIPT")

DRIVER="$(git -C "$R1" config merge.ours.driver)"
[ "$DRIVER" = "true" ] \
  || fail "Test 1: merge.ours.driver not set to 'true' (got: '$DRIVER')"

pass "Test 1: merge.ours.driver = true installed in repo config"

# ---------------------------------------------------------------------------
# Test 2: appends '.pr-body.md merge=ours' to .gitattributes
# ---------------------------------------------------------------------------
grep -qF '.pr-body.md merge=ours' "$R1/.gitattributes" \
  || fail "Test 2: .pr-body.md merge=ours not found in .gitattributes"

pass "Test 2: .gitattributes contains .pr-body.md merge=ours"

# ---------------------------------------------------------------------------
# Test 3: idempotent — second run does not duplicate the entry
# ---------------------------------------------------------------------------
(cd "$R1" && bash "$SCRIPT")
(cd "$R1" && bash "$SCRIPT")

COUNT="$(grep -cF '.pr-body.md merge=ours' "$R1/.gitattributes")"
[ "$COUNT" -eq 1 ] \
  || fail "Test 3: .gitattributes has $COUNT duplicate entries (expected exactly 1)"

pass "Test 3: idempotent — no duplicate .gitattributes entries after 3 runs"

# ---------------------------------------------------------------------------
# Test 4: merge simulation — branch keeps its .pr-body.md when main diverges
# ---------------------------------------------------------------------------
R2="$TMP/r2"
make_repo "$R2"

# Seed: initial commit on main
echo "initial" > "$R2/.pr-body.md"
git -C "$R2" add .pr-body.md
git -C "$R2" commit -qm "init"

# Install the merge=ours driver + gitattribute on main
(cd "$R2" && bash "$SCRIPT")
git -C "$R2" add .gitattributes
git -C "$R2" commit -qm "install merge=ours"

# Create feature branch; write branch-local PR body
git -C "$R2" switch -qc feature
printf '## Summary\n\nbranch-local body\n\nFixes #96\n' > "$R2/.pr-body.md"
git -C "$R2" add .pr-body.md
git -C "$R2" commit -qm "branch PR body"

BRANCH_BODY="$(cat "$R2/.pr-body.md")"

# Back on main — simulate a squash-merge: main's .pr-body.md gets overwritten
git -C "$R2" switch -q main
printf '## Summary\n\nlast merged PR body (from some other PR)\n\nFixes #999\n' > "$R2/.pr-body.md"
git -C "$R2" commit -qam "main PR body update (simulated squash)"

# Merge main into feature — must not conflict; branch body must be preserved
git -C "$R2" switch -q feature
git -C "$R2" merge -q --no-edit main \
  || fail "Test 4: merge failed (expected no conflict)"

AFTER_MERGE="$(cat "$R2/.pr-body.md")"

[ "$AFTER_MERGE" = "$BRANCH_BODY" ] \
  || fail "Test 4: branch .pr-body.md was overwritten by main during merge.
  Expected: $BRANCH_BODY
  Got:      $AFTER_MERGE"

pass "Test 4: merge kept branch .pr-body.md — no conflict, branch content preserved"

# ---------------------------------------------------------------------------
# Test 5: exits 0 in a repo that already has a .gitattributes with other rules
# ---------------------------------------------------------------------------
R3="$TMP/r3"
make_repo "$R3"
echo "init" > "$R3/f.txt"
git -C "$R3" add f.txt
git -C "$R3" commit -qm init
printf '*.lock merge=binary\n*.json merge=binary\n' > "$R3/.gitattributes"

EXIT_CODE=0
(cd "$R3" && bash "$SCRIPT") || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 0 ] \
  || fail "Test 5: non-zero exit when .gitattributes already has other rules"

grep -qF '.pr-body.md merge=ours' "$R3/.gitattributes" \
  || fail "Test 5: entry not appended to existing .gitattributes"

EXISTING="$(grep -c 'merge=binary' "$R3/.gitattributes")"
[ "$EXISTING" -eq 2 ] \
  || fail "Test 5: pre-existing .gitattributes rules were altered (expected 2 merge=binary lines)"

pass "Test 5: appends to existing .gitattributes without disturbing other rules"

echo ""
echo "✓ merge-ours-prbody: all checks passed"
