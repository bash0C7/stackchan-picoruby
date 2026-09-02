#!/bin/zsh
zmodload zsh/datetime
# Per-face wall-clock profile over BLE. latency_baseline.zsh labels every face
# sample `face-N`, so they collapse into one row and the per-face structure is
# lost — and that structure is the whole signal: a face's cost is set by its
# geometry, not by the verb. Rounds interleave the faces so drift hits all of
# them equally.
#
#   ROUNDS=8 tools/face_profile.zsh          # -> /tmp/stackchan-picoruby-debug/face-profile.log
cd "$(dirname "$0")/.." || exit 2
S=pc/stackchan-pico/bin/stackchan
LOG=${LOG:-/tmp/stackchan-picoruby-debug/face-profile.log}
ROUNDS=${ROUNDS:-8}
mkdir -p "$(dirname $LOG)"
: > $LOG
faces=(neutral smile joy surprised sad angry)
for r in $(seq 1 $ROUNDS); do
  for f in $faces; do
    t0=$EPOCHREALTIME
    out=$($S face $f 2>&1); rc=$?
    t1=$EPOCHREALTIME
    printf '%s\t%.3f\trc=%d\t%s\n' "face-$f" $((t1 - t0)) $rc "${out//$'\n'/ | }" >> $LOG
  done
done
# The floor: same BLE round trip, no LCD work.
for r in $(seq 1 5); do
  t0=$EPOCHREALTIME; out=$($S led both red solid 2>&1); rc=$?; t1=$EPOCHREALTIME
  printf '%s\t%.3f\trc=%d\t%s\n' "led" $((t1 - t0)) $rc "${out//$'\n'/ | }" >> $LOG
done
echo
ruby tools/latency_summary.rb $LOG
