#!/bin/bash
# Generic device-probe harness: flash a probe, reset the board, run a Mac-side
# counterpart against it, and capture both sides of the conversation in one go.
#
#   PROBE=<path.rb> COUNTERPART=<AppName> [DURATION=90] [SETTLE=20] \
#     [COUNTERPART_ENV="--env K=V --env K2=V2"] tools/run_device_probe.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROBE=${PROBE:?PROBE=path/to/probe.rb required}
COUNTERPART=${COUNTERPART:?COUNTERPART=AppName required}
COUNTERPART_ENV=${COUNTERPART_ENV:-}
COUNTERPART_ARGS=${COUNTERPART_ARGS:-}
DURATION=${DURATION:-90}
SETTLE=${SETTLE:-20}
BOOT_WAIT=${BOOT_WAIT:-12}
DEV_LOG=${DEV_LOG:-/tmp/probe_device.log}
MAC_LOG=${MAC_LOG:-/tmp/probe_mac.log}
MAX_TRIES=${MAX_TRIES:-3}

eval "$(rbenv init -)"
cd "$REPO" || exit 1

echo "[harness] probe=$PROBE counterpart=$COUNTERPART duration=${DURATION}s"

uploaded=0
for i in $(seq 1 "$MAX_TRIES"); do
  echo "[harness] upload attempt $i/$MAX_TRIES (settle ${SETTLE}s)"
  bundle exec rake r2p2:wipe_storage >/tmp/probe_wipe.log 2>&1
  sleep "$SETTLE"
  if SRC="$PROBE" bundle exec rake r2p2:upload_appmrb >/tmp/probe_upload.log 2>&1 \
     && grep -q 'DONE_ACK ok' /tmp/probe_upload.log; then
    echo "[harness] upload OK"
    uploaded=1
    break
  fi
  echo "[harness] upload failed; retrying"
done
[ "$uploaded" -eq 1 ] || { echo "HARNESS-FAIL upload"; tail -20 /tmp/probe_upload.log; exit 1; }

# Serial capture runs in the background so the Mac counterpart can talk to the
# board while it is being recorded.
SERIAL_LOG="$DEV_LOG" DURATION="$DURATION" bundle exec rake r2p2:reset_and_capture \
  >/tmp/probe_capture.log 2>&1 &
CAP=$!

echo "[harness] waiting ${BOOT_WAIT}s for the probe to boot and advertise"
sleep "$BOOT_WAIT"

# shellcheck disable=SC2086
open -W -a "$HOME/Applications/$COUNTERPART.app" \
  --stdout "$MAC_LOG" --stderr "$MAC_LOG" $COUNTERPART_ENV $COUNTERPART_ARGS
MAC_RC=$?

wait $CAP 2>/dev/null

echo "===================== MAC SIDE ($COUNTERPART, rc=$MAC_RC) ====================="
cat "$MAC_LOG"
echo "===================== DEVICE SIDE ====================="
grep -a "probe\]" "$DEV_LOG" || echo "(no probe lines captured)"
echo "===================== ERRORS ====================="
grep -aiE "Guru Meditation|NoMethodError|ArgumentError|FAIL" "$DEV_LOG" "$MAC_LOG" || echo "(none)"
exit "$MAC_RC"
