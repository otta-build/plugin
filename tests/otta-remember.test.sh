#!/usr/bin/env bash
# otta-remember.test.sh — regression tests for scripts/otta-remember.sh.
#
# Covers AC1–AC3:
#   AC1: appends a dated entry to LEARNINGS.md; creates the file with a header if absent
#   AC2: rejects invalid categories (non-zero exit, writes nothing)
#   AC3: idempotent on exact duplicate (no second entry appended)
# Run: bash tests/otta-remember.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-remember.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

# ---------------------------------------------------------------------------
# 1. AC1 — creates LEARNINGS.md with header and dated entry when absent
# ---------------------------------------------------------------------------
D="$TMP/test1"; mkdir -p "$D"; cd "$D"
[ ! -f LEARNINGS.md ] || fail "precondition: LEARNINGS.md should not exist yet"
bash "$SCRIPT" decision "use SQLite before splitting to DuckDB" || fail "exit non-zero on valid call"
[ -f LEARNINGS.md ] || fail "LEARNINGS.md was not created"
grep -q '\[decision\]' LEARNINGS.md || fail "entry missing [decision] tag"
grep -q 'use SQLite before splitting to DuckDB' LEARNINGS.md || fail "entry missing the learning text"
grep -Eq '^- [0-9]{4}-[0-9]{2}-[0-9]{2} \[decision\] use SQLite before splitting to DuckDB' LEARNINGS.md \
  || fail "entry is not dated in the expected structured shape (YYYY-MM-DD [category] text)"
# header line should exist
grep -q '^# Learnings' LEARNINGS.md || fail "LEARNINGS.md missing header line"
pass "AC1: creates LEARNINGS.md with header and dated entry"

# ---------------------------------------------------------------------------
# 2. AC1 cont. — appends to existing LEARNINGS.md (file already present)
# ---------------------------------------------------------------------------
D="$TMP/test2"; mkdir -p "$D"; cd "$D"
printf '# Learnings\n\n' > LEARNINGS.md
bash "$SCRIPT" gotcha "always quote paths with spaces" || fail "exit non-zero on second call"
grep -q '\[gotcha\]' LEARNINGS.md || fail "entry missing [gotcha] tag"
grep -q 'always quote paths with spaces' LEARNINGS.md || fail "entry missing learning text"
pass "AC1: appends to existing LEARNINGS.md"

# ---------------------------------------------------------------------------
# 3. AC1 — all three valid categories are accepted
# ---------------------------------------------------------------------------
D="$TMP/test3"; mkdir -p "$D"; cd "$D"
bash "$SCRIPT" decision "a decision" || fail "decision category rejected"
bash "$SCRIPT" gotcha "a gotcha" || fail "gotcha category rejected"
bash "$SCRIPT" failed-approach "a failed approach" || fail "failed-approach category rejected"
grep -q '\[decision\]' LEARNINGS.md       || fail "decision entry missing"
grep -q '\[gotcha\]' LEARNINGS.md         || fail "gotcha entry missing"
grep -q '\[failed-approach\]' LEARNINGS.md || fail "failed-approach entry missing"
pass "AC1: all three valid categories (decision, gotcha, failed-approach) accepted"

# ---------------------------------------------------------------------------
# 4. AC2 — invalid category exits non-zero and writes nothing
# ---------------------------------------------------------------------------
D="$TMP/test4"; mkdir -p "$D"; cd "$D"
if bash "$SCRIPT" typo "some text" >/dev/null 2>&1; then
  fail "invalid category should exit non-zero"
fi
[ ! -f LEARNINGS.md ] || fail "LEARNINGS.md should not be created on invalid category"
pass "AC2: invalid category exits non-zero and writes nothing"

# ---------------------------------------------------------------------------
# 5. AC2 — another invalid category (empty-string-like value)
# ---------------------------------------------------------------------------
D="$TMP/test5"; mkdir -p "$D"; cd "$D"
if bash "$SCRIPT" note "some text" >/dev/null 2>&1; then
  fail "category 'note' should be rejected"
fi
[ ! -f LEARNINGS.md ] || fail "LEARNINGS.md should not be created for rejected category"
pass "AC2: category 'note' rejected"

# ---------------------------------------------------------------------------
# 6. AC3 — exact duplicate re-run: only one entry appended
# ---------------------------------------------------------------------------
D="$TMP/test6"; mkdir -p "$D"; cd "$D"
bash "$SCRIPT" decision "prefer explicit over implicit" || fail "first run failed"
bash "$SCRIPT" decision "prefer explicit over implicit" || fail "second run failed"
count="$(grep -c '\[decision\] prefer explicit over implicit' LEARNINGS.md)"
[ "$count" = "1" ] || fail "expected 1 entry after dedup, found $count"
pass "AC3: exact duplicate not appended twice (count == 1)"

# ---------------------------------------------------------------------------
# 7. Usage guard — missing args exit non-zero
# ---------------------------------------------------------------------------
D="$TMP/test7"; mkdir -p "$D"; cd "$D"
if bash "$SCRIPT" >/dev/null 2>&1; then fail "no args should exit non-zero"; fi
if bash "$SCRIPT" decision >/dev/null 2>&1; then fail "missing text should exit non-zero"; fi
[ ! -f LEARNINGS.md ] || fail "LEARNINGS.md should not be created on usage error"
pass "usage guard: missing args rejected"

echo "All otta-remember tests passed."
