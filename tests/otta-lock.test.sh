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

# 3. timeout returns non-zero when the lock is already held
LOCK3="$TMP/l3"; mkdir "$LOCK3"
if otta_lock_acquire "$LOCK3" 1 >/dev/null 2>&1; then fail "should time out on held lock"; fi
rmdir "$LOCK3"

echo "✓ otta-lock: all 3 checks passed"
