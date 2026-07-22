#!/usr/bin/env bash
# otta-lock.sh — portable mkdir-based mutex. `flock` is absent on macOS, so we
# use mkdir, which is atomic on every POSIX filesystem. Source this file, then:
#   otta_lock_acquire <lock-dir> [timeout-seconds]   # default 30s
#   otta_lock_release <lock-dir>
# A dead holder leaves a stale lock dir; acquire then times out and the caller
# fails that lane (never the batch). Locks guard sub-second critical sections,
# so a timeout means real trouble, not normal contention.

otta_lock_acquire() {
  local lock="$1" timeout="${2:-30}" waited=0 max
  max=$((timeout * 10))
  until mkdir "$lock" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -ge "$max" ]; then
      echo "otta-lock: timeout after ${timeout}s acquiring $lock" >&2
      return 1
    fi
  done
  return 0
}

otta_lock_release() {
  rmdir "$1" 2>/dev/null || true
}
