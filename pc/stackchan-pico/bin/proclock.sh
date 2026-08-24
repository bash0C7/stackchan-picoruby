#!/bin/sh
# mkdir-based atomic lock helpers for POSIX sh. macOS ships no flock(1)
# (util-linux only); mkdir is atomic across processes on every POSIX
# filesystem and needs no extra dependency, so it's the lock primitive here.
#
# A lock is a directory. The lockdir contains a `pid` file naming the
# holder's PID, so a waiter can detect a lock left behind by a process that
# died without calling release_lock (crash, kill -9, etc.) and reclaim it
# immediately instead of waiting out the full timeout.
#
# Usage:
#   . "$(dirname "$0")/proclock.sh"
#   acquire_lock "$LOGDIR/daemon.lockdir" 45 || exit 1
#   ...critical section...
#   release_lock "$LOGDIR/daemon.lockdir"

# acquire_lock LOCKDIR TIMEOUT_S
# Blocks (polling once per second) until the lock is held or TIMEOUT_S
# elapses. Returns 0 once held, 1 on timeout.
acquire_lock() {
  lockdir="$1"
  timeout_s="$2"
  waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    holder_pid=""
    [ -f "$lockdir/pid" ] && holder_pid=$(cat "$lockdir/pid" 2>/dev/null)
    if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
      # Stale: the recorded holder is dead. Multiple waiters may race to
      # clear this at once -- rmdir on an already-removed or since-recreated
      # dir just fails harmlessly and we loop back to mkdir.
      rm -f "$lockdir/pid" 2>/dev/null
      rmdir "$lockdir" 2>/dev/null
      continue
    fi
    if [ "$waited" -ge "$timeout_s" ]; then
      echo "stackchan: timed out waiting ${timeout_s}s for lock $lockdir (held by pid ${holder_pid:-unknown})" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo $$ > "$lockdir/pid"
  return 0
}

# release_lock LOCKDIR
release_lock() {
  lockdir="$1"
  rm -f "$lockdir/pid" 2>/dev/null
  rmdir "$lockdir" 2>/dev/null
}
