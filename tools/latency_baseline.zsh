#!/bin/zsh
zmodload zsh/datetime
# Baseline wall-clock measurement of stackchan CLI verbs (end-to-end, includes wrapper overhead).
# On failure (ACK timeout etc.) the backends are rebuilt with `rake pc:up` before the next sample.
cd "$(dirname "$0")/.." || exit 2
S=pc/stackchan-pico/bin/stackchan
LOG=${LOG:-/tmp/stackchan-picoruby-debug/baseline.log}
: > $LOG
# `stackchan stop` never replies: Daemon#stop calls DRb.stop_service, which
# terminates the very Task the method is running in, so the lines after it and
# the reply itself are unreachable — and the TCP transport has no read timeout,
# so one recovery here would hang the whole run. `rake pc:up` is the
# deterministic rebuild instead: it boots both launchd jobs out, waits for
# launchd to release them, bootstraps them again, and only returns once the
# daemon answers status with ble_connected. Nothing is left to retry after it.
recover() {
  if bundle exec rake pc:up >>$LOG 2>&1; then
    echo "recovered (rake pc:up)" | tee -a $LOG; return 0
  fi
  echo "RECOVERY FAILED (rake pc:up — see $LOG)" | tee -a $LOG; return 1
}
run() {
  local label="$1"; shift
  local t0=$EPOCHREALTIME
  local out; out=$("$@" 2>&1); local rc=$?
  local t1=$EPOCHREALTIME
  local short=${out//$'\n'/ | }
  printf '%s\t%.3f\trc=%d\t%s\n' "$label" $((t1 - t0)) $rc "${short:0:140}" | tee -a $LOG
  if (( rc != 0 )); then recover || exit 3; fi
}
# wrapper floor: a verb that never touches BLE
for i in 1 2 3; do run "status-$i" $S status; done
faces=(neutral joy smile sad surprised angry neutral joy smile sad surprised angry neutral joy smile sad surprised angry neutral joy)
for i in {1..20}; do run "face-$i" $S face ${faces[$i]}; done
for i in {1..10}; do run "servo-$i" $S servo --yaw-left 0 --pitch-up 0 --time 300; done
for i in {1..10}; do run "led-$i" $S led both red solid; done
run "torque-off" $S torque off
run "say-1" $S say "テスト" --gain 0.1
echo "=== done ===" | tee -a $LOG
echo
ruby tools/latency_summary.rb $LOG
