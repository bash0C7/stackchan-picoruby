#!/bin/bash
# Self-driving harness for the short-advertising-report (36d99a94) verification.
# One invocation: flash probe -> reset -> capture -> parse -> verdict.
# The wipe before each upload is required, not defensive: the probe app is an
# autostart payload that never returns, so until it is erased main_task.rb
# never reaches `$shell.start` and picomodem has nothing to talk to. The retry
# loop remains as a safety net so the run needs no interactive supervision.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROBE=${PROBE:-/tmp/adv_probe.rb}
LOG=${LOG:-/tmp/adv_probe_capture.log}
DURATION=${DURATION:-90}
MAX_TRIES=${MAX_TRIES:-6}

eval "$(rbenv init -)"
cd "$REPO" || exit 1

echo "[harness] probe=$PROBE duration=${DURATION}s"

uploaded=${SKIP_UPLOAD:-0}
SETTLE=${SETTLE:-30}
for i in $(seq 1 "$MAX_TRIES"); do
  [ "$uploaded" -eq 1 ] && break
  echo "[harness] upload attempt $i/$MAX_TRIES (settle ${SETTLE}s)"
  bundle exec rake r2p2:wipe_storage >/tmp/adv_probe_wipe.log 2>&1
  sleep "$SETTLE"
  if SRC="$PROBE" bundle exec rake r2p2:upload_appmrb >/tmp/adv_probe_upload.log 2>&1 \
     && grep -q 'DONE_ACK ok' /tmp/adv_probe_upload.log; then
    echo "[harness] upload OK on attempt $i"
    uploaded=1
    break
  fi
  echo "[harness] upload failed (picomodem handshake); retrying"
done

if [ "$uploaded" -ne 1 ]; then
  echo "HARNESS-FAIL: could not upload probe after $MAX_TRIES attempts"
  exit 1
fi

echo "[harness] capturing ${DURATION}s of serial while the probe scans"
SERIAL_LOG="$LOG" DURATION="$DURATION" bundle exec rake r2p2:reset_and_capture \
  >/tmp/adv_probe_capture_run.log 2>&1

echo "===================== RAW EVIDENCE ====================="
echo "--- negative control (pre-fix 12-byte packet) ---"
grep -a 'probe. NEGCTL' "$LOG" | head -3
echo "--- live short reports ---"
grep -a 'probe. SHORT' "$LOG" | head -8
echo "--- last summary ---"
grep -a 'probe. SUMMARY' "$LOG" | tail -1
echo "--- any parse failures ---"
grep -a 'PARSE_FAIL' "$LOG" | head -10
echo "--- any ruby-level exception in log ---"
grep -aiE 'ArgumentError|Guru Meditation|abort\(\)|backtrace' "$LOG" | head -10

echo "===================== VERDICT ====================="
last=$(grep -a 'probe. SUMMARY' "$LOG" | tail -1)
if [ -z "$last" ]; then
  echo "FAIL: probe never produced a summary line (app did not run?)"
  tail -25 "$LOG"
  exit 1
fi

total=$(echo "$last"  | sed -n 's/.*total=\([0-9]*\).*/\1/p')
d0=$(echo "$last"     | sed -n 's/.*dlen0=\([0-9]*\).*/\1/p')
d1=$(echo "$last"     | sed -n 's/.*dlen1=\([0-9]*\).*/\1/p')
badpad=$(echo "$last" | sed -n 's/.*badpad=\([0-9]*\).*/\1/p')
fail=$(echo "$last"   | sed -n 's/.*fail=\([0-9]*\).*/\1/p')
short=$((d0 + d1))

echo "adv reports received : $total"
echo "dlen==0 reports      : $d0"
echo "dlen==1 reports      : $d1"
echo "short total          : $short"
echo "padding violations   : $badpad   (raw<14 or len1!=raw-2)"
echo "parse failures       : $fail"

negctl=$(grep -a 'probe. NEGCTL' "$LOG" | tail -1)
echo "negative control     : ${negctl:-<missing>}"

rc=0
case "$negctl" in
  *"raised=yes"*) : ;;
  *) echo "FAIL: negative control did not raise -- probe cannot detect the bug"; rc=1 ;;
esac
[ "$short"  -gt 0 ] || { echo "INCONCLUSIVE: no dlen<=1 report observed in ${DURATION}s"; rc=2; }
[ "$badpad" -eq 0 ] || { echo "FAIL: short report not padded to the 14-byte contract"; rc=1; }
[ "$fail"   -eq 0 ] || { echo "FAIL: AdvertisingReport raised on a short report"; rc=1; }

if [ "$rc" -eq 0 ]; then
  echo "PASS: $short short report(s) reached Ruby, all padded to >=14 bytes, none raised."
fi
exit "$rc"
