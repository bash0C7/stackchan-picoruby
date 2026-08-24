#!/bin/sh
# Manual integration test for proclock.sh. Run directly:
#   sh pc/stackchan-pico/test/proclock_test.sh
set -eu
cd "$(dirname "$0")/.."
. bin/proclock.sh

fail() { echo "FAIL: $1"; exit 1; }

TMPDIR_TEST=$(mktemp -d)
LOCKDIR="$TMPDIR_TEST/test.lockdir"

# Test 1: acquire then release, lockdir gone after release.
acquire_lock "$LOCKDIR" 5 || fail "acquire_lock should succeed when unlocked"
[ -d "$LOCKDIR" ] || fail "lockdir should exist while held"
release_lock "$LOCKDIR"
[ -d "$LOCKDIR" ] && fail "lockdir should be gone after release"
echo "PASS: acquire/release round trip"

# Test 2: a waiter blocks while a genuinely live holder has the lock, then
# acquires once that holder releases (not before).
(
  . bin/proclock.sh
  acquire_lock "$LOCKDIR" 5
  sleep 2
  release_lock "$LOCKDIR"
) &
holder_bg=$!
sleep 0.5
start=$(date +%s)
acquire_lock "$LOCKDIR" 10 || fail "acquire_lock should eventually succeed after holder releases"
elapsed=$(($(date +%s) - start))
[ "$elapsed" -ge 1 ] || fail "acquire_lock returned suspiciously fast (expected to wait on live holder)"
release_lock "$LOCKDIR"
wait "$holder_bg" 2>/dev/null || true
echo "PASS: waiter blocks on live holder, then acquires"

# Test 3: a stale lock (holder pid recorded but that pid is dead) is
# reclaimed promptly, not after the full timeout.
mkdir "$LOCKDIR"
echo 999999 > "$LOCKDIR/pid"
start=$(date +%s)
acquire_lock "$LOCKDIR" 10 || fail "acquire_lock should reclaim a stale lock"
elapsed=$(($(date +%s) - start))
[ "$elapsed" -le 3 ] || fail "stale lock reclaim took too long (${elapsed}s), expected near-immediate"
release_lock "$LOCKDIR"
echo "PASS: stale lock reclaimed without waiting out the timeout"

# Test 4: acquire_lock returns 1 (not hang) when the lock genuinely never
# frees within the timeout.
mkdir "$LOCKDIR"
echo $$ > "$LOCKDIR/pid"   # our own pid: alive, so this is a genuine live hold
if acquire_lock "$LOCKDIR" 2; then
  fail "acquire_lock should have timed out (lock held by a live pid)"
fi
rm -f "$LOCKDIR/pid"
rmdir "$LOCKDIR"
echo "PASS: acquire_lock times out instead of hanging"

rm -rf "$TMPDIR_TEST"
echo "ALL PASS"
