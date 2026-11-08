#!/bin/zsh
cd "$(dirname "$0")/.." || exit 2
VM=${STACKCHAN_PICORUBY:-vendor/R2P2-darwin/build/host/bin/picoruby}
$VM tools/ambient_demo.rb "$PWD" &
pid=$!
trap 'kill $pid 2>/dev/null; $VM tools/ambient_demo.rb "$PWD" rest; exit 0' INT TERM
wait $pid
