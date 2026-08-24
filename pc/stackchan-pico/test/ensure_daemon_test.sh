#!/bin/sh
# Manual integration test for ensure_daemon's PID-file identity. Run
# directly (fake BLE mode, no hardware needed):
#   sh pc/stackchan-pico/test/ensure_daemon_test.sh
set -eu
cd "$(dirname "$0")/.."
export STACKCHAN_BLE_FAKE=1
export STACKCHAN_PORT=18787   # distinct from the default 8787, avoids clobbering a real session
export STACKCHAN_SIDECAR_PORT=18788
export STACKCHAN_LOGDIR="$(mktemp -d)"
export STACKCHAN_SIDECAR_STUB=1

fail() { echo "FAIL: $1"; exit 1; }
cleanup() {
  bin/stackchan stop >/dev/null 2>&1 || true
  pkill -9 -f "ruby.*pc/sidecar/sidecar\.rb.*$STACKCHAN_SIDECAR_PORT" 2>/dev/null || true
  rm -rf "$STACKCHAN_LOGDIR"
}
trap cleanup EXIT

# Test 1: after a normal verb call, daemon.pid names a live process that
# is actually the spawned daemon.
bin/stackchan status >/dev/null 2>&1 || true   # status alone doesn't spawn
bin/stackchan torque on >/dev/null 2>&1 || fail "torque on should succeed in fake mode"
[ -f "$STACKCHAN_LOGDIR/daemon.pid" ] || fail "daemon.pid should exist after a verb call"
daemon_pid=$(cat "$STACKCHAN_LOGDIR/daemon.pid")
ps -p "$daemon_pid" >/dev/null 2>&1 || fail "daemon.pid ($daemon_pid) should name a live process"
ps -p "$daemon_pid" -o command= | grep -q "boot_daemon\.rb" || fail "daemon.pid should be the boot_daemon.rb process"
echo "PASS: daemon.pid names the real daemon process"

# Test 2: killing the recorded pid directly, then calling a verb again,
# triggers a fresh spawn (not a hang) and daemon.pid is updated to a
# different, live pid.
kill -9 "$daemon_pid"
sleep 1
bin/stackchan torque on >/dev/null 2>&1 || fail "torque on should succeed after the daemon died out from under it"
new_pid=$(cat "$STACKCHAN_LOGDIR/daemon.pid")
[ "$new_pid" != "$daemon_pid" ] || fail "daemon.pid should have changed after respawn"
ps -p "$new_pid" >/dev/null 2>&1 || fail "new daemon.pid ($new_pid) should name a live process"
echo "PASS: daemon respawns and daemon.pid tracks the new process"

echo "ALL PASS"
