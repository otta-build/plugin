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
  local lock="$1" timeout="${2:-60}" stale now m age deadline base attempt=0
  stale="${OTTA_LOCK_STALE_SECS:-300}"
  # Wall-clock deadline, NOT an iteration count: under a loaded/constrained
  # runner (few cores, many spinners) a `sleep 0.1 × N` counter fires early and
  # starves lanes; a real deadline waits the actual `timeout` seconds.
  deadline=$(( $(date +%s) + timeout ))
  # Per-process jitter seed, computed ONCE. $RANDOM is SHARED across forked `&`
  # subshells (identical sequences → no desync) and $BASHPID can be empty, so use
  # /dev/urandom — but only once: forking od/tr on EVERY retry fork-storms a
  # 2-core runner and starves the lock holder's own work.
  base="$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')"
  [ -n "$base" ] || base=$$
  until mkdir "$lock" 2>/dev/null; do
    attempt=$((attempt + 1))
    # Check stale-steal + deadline only periodically to keep the hot spin cheap
    # (each check forks date/stat). Self-heal a dead holder's stale lock; GNU
    # `stat -c %Y` first, BSD/macOS `stat -f %m` fallback.
    if [ $((attempt % 8)) -eq 0 ]; then
      now="$(date +%s)"
      m="$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo "$now")"
      age=$((now - m))
      if [ "$age" -ge "$stale" ]; then
        rmdir "$lock" 2>/dev/null || true
        continue
      fi
      if [ "$now" -ge "$deadline" ]; then
        echo "otta-lock: timeout after ${timeout}s acquiring $lock" >&2
        return 1
      fi
    fi
    # Arithmetic jitter (0.02–0.09s): per-process offset + per-retry increment,
    # no forking. Desyncs synchronized spinners without a thundering herd.
    sleep "0.0$(( (base + attempt) % 8 + 2 ))"
  done
  return 0
}

otta_lock_release() {
  rmdir "$1" 2>/dev/null || true
}
