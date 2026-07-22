#!/usr/bin/env bash
# Regression test for otta-lock.sh — portable mkdir mutex (flock absent on macOS).
# Run: bash tests/otta-lock.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-lock.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

# shellcheck source=/dev/null
. "$SCRIPT"

# 1. acquire creates the lock dir; release removes it
LOCK="$TMP/l1"
otta_lock_acquire "$LOCK" || fail "acquire failed on free lock"
[ -d "$LOCK" ] || fail "lock dir not created"
otta_lock_release "$LOCK"
[ -d "$LOCK" ] && fail "lock dir not removed on release"

# 2. mutual exclusion: 20 concurrent incrementers of a shared counter never lose a write
COUNT="$TMP/count"; echo 0 > "$COUNT"
LOCK2="$TMP/l2"
inc() {
  otta_lock_acquire "$LOCK2" || exit 1
  n="$(cat "$COUNT")"; echo $((n + 1)) > "$COUNT"
  otta_lock_release "$LOCK2"
}
for _ in $(seq 20); do inc & done
wait
[ "$(cat "$COUNT")" = "20" ] || fail "lost updates under contention: got $(cat "$COUNT"), want 20"

# 3. timeout returns non-zero when the lock is already held (fresh, not stale)
LOCK3="$TMP/l3"; mkdir "$LOCK3"
if otta_lock_acquire "$LOCK3" 1 >/dev/null 2>&1; then fail "should time out on held lock"; fi
rmdir "$LOCK3"

# 4. a stale lock (dir older than the stale threshold) is stolen, not waited on
LOCK4="$TMP/l4"; mkdir "$LOCK4"
touch -t 202001010000 "$LOCK4"   # backdate the dir mtime to 2020
OTTA_LOCK_STALE_SECS=300 otta_lock_acquire "$LOCK4" 2 || fail "stale lock not stolen"
[ -d "$LOCK4" ] || fail "stolen lock should be re-held (dir present)"
otta_lock_release "$LOCK4"

echo "✓ otta-lock: all 4 checks passed"
