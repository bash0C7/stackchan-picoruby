#!/bin/sh
# Manual integration test: run_with_watchdog.rb must capture diagnostics
# even when the wrapped command fails fast (no timeout), not only when it
# hangs. Run directly:
#   sh pc/stackchan-pico/test/watchdog_fast_failure_test.sh
set -eu
cd "$(dirname "$0")/.."
export STACKCHAN_LOGDIR="$(mktemp -d)"

fail() { echo "FAIL: $1"; exit 1; }
trap 'rm -rf "$STACKCHAN_LOGDIR"' EXIT

before_count=$(find "$STACKCHAN_LOGDIR/hang-incidents" -type f 2>/dev/null | wc -l | tr -d ' ')

# "false" exits 1 immediately -- a fast failure, not a hang.
set +e
ruby bin/run_with_watchdog.rb 5 fast_fail_test false
rc=$?
set -e

[ "$rc" -eq 1 ] || fail "expected exit code 1 (propagated from 'false'), got $rc"

after_count=$(find "$STACKCHAN_LOGDIR/hang-incidents" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$after_count" -gt "$before_count" ] || fail "expected a new file under hang-incidents/ for the fast failure, found none"
echo "PASS: fast failure produces a diagnostic incident file"

# A genuine timeout still produces one too (regression guard on existing behavior).
set +e
ruby bin/run_with_watchdog.rb 1 hang_test sleep 5
rc=$?
set -e
[ "$rc" -eq 124 ] || fail "expected exit code 124 for a real timeout, got $rc"
after_hang_count=$(find "$STACKCHAN_LOGDIR/hang-incidents" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$after_hang_count" -gt "$after_count" ] || fail "expected another new file under hang-incidents/ for the timeout case"
echo "PASS: timeout still produces a diagnostic incident file (no regression)"

# A clean success produces no incident file.
before_ok_count=$(find "$STACKCHAN_LOGDIR/hang-incidents" -type f 2>/dev/null | wc -l | tr -d ' ')
ruby bin/run_with_watchdog.rb 5 ok_test true
after_ok_count=$(find "$STACKCHAN_LOGDIR/hang-incidents" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$after_ok_count" -eq "$before_ok_count" ] || fail "a clean success should not create an incident file"
echo "PASS: clean success creates no incident file"

echo "ALL PASS"
