#!/usr/bin/env bash
# otta-lock.sh — portable mkdir-based mutex. `flock` is absent on macOS, so we
# use mkdir, which is atomic on every POSIX filesystem. Source this file, then:
#   otta_lock_acquire <lock-dir> [timeout-seconds]   # default 30s
#   otta_lock_release <lock-dir>
# Critical sections here are sub-second. A holder killed mid-section (SIGKILL,
# workflow timeout) would leave a stale lock dir and wedge every future call for
# that repo. To self-heal, acquire steals a lock whose dir is older than
# OTTA_LOCK_STALE_SECS (default 300s — far longer than any real hold, so a live
# lock is never stolen).

otta_lock_acquire() {
  local lock="$1" timeout="${2:-30}" waited=0 max stale now m age
  max=$((timeout * 10))
  stale="${OTTA_LOCK_STALE_SECS:-300}"
  until mkdir "$lock" 2>/dev/null; do
    # Self-heal: steal a lock left behind by a dead holder. GNU `stat -c %Y`
    # first, BSD/macOS `stat -f %m` fallback (same order used elsewhere).
    now="$(date +%s)"
    m="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo "$now")"
    age=$((now - m))
    if [ "$age" -ge "$stale" ]; then
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
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
