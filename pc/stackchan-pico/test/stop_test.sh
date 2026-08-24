#!/bin/sh
# Manual integration test: stackchan stop must actually terminate the
# daemon process (fake BLE mode -- this is a process-lifecycle assertion,
# not a BLE-disconnect assertion; the real-BLE-disconnect claim is verified
# on hardware separately, see the design doc's test plan item 4).
set -eu
cd "$(dirname "$0")/.."
export STACKCHAN_BLE_FAKE=1
export STACKCHAN_PORT=18790
export STACKCHAN_SIDECAR_PORT=18791
export STACKCHAN_LOGDIR="$(mktemp -d)"
export STACKCHAN_SIDECAR_STUB=1

fail() { echo "FAIL: $1"; exit 1; }
cleanup() {
  pkill -9 -f "ruby.*pc/sidecar/sidecar\.rb.*$STACKCHAN_SIDECAR_PORT" 2>/dev/null || true
  rm -rf "$STACKCHAN_LOGDIR"
}
trap cleanup EXIT

bin/stackchan torque on >/dev/null 2>&1 || fail "setup: torque on should succeed"
daemon_pid=$(cat "$STACKCHAN_LOGDIR/daemon.pid")
ps -p "$daemon_pid" >/dev/null 2>&1 || fail "setup: daemon should be alive before stop"

bin/stackchan stop || fail "stop should exit 0"

sleep 0.5
ps -p "$daemon_pid" >/dev/null 2>&1 && fail "daemon process should be dead after stop"
[ -f "$STACKCHAN_LOGDIR/daemon.pid" ] && fail "daemon.pid should be removed after stop"
echo "PASS: stop kills the daemon process and clears daemon.pid"

# stop on an already-stopped daemon is a clean no-op, not an error.
bin/stackchan stop || fail "stop on an already-stopped daemon should still exit 0"
echo "PASS: stop is idempotent"

echo "ALL PASS"
