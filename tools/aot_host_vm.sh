#!/usr/bin/env bash
# Build a host picoruby VM carrying the AOT kernels (direct calls and the
# multicore_kernels table) and picoruby-multicore's pthread port, for the
# benches under bench/.
#
#   tools/aot/setup.sh            # once: suppify, spinel, picoruby-multicore at their pins
#   tools/aot_host_vm.sh
#   build/host-aot/bin/picoruby bench/aot_ab.rb
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PICORUBY_ROOT=${PICORUBY_ROOT:-$ROOT/vendor/R2P2-ESP32/components/picoruby-esp32/picoruby}

ruby "$ROOT/tools/aot/kernels_build.rb" host
# picoruby's object rule keys on mtime, so a regenerated gem needs a clean build dir.
rm -rf "$ROOT/build/host-aot"
(cd "$PICORUBY_ROOT" && MRUBY_CONFIG="$ROOT/build_config/picoruby-aot-host.rb" MRUBY_BUILD_DIR="$ROOT/build" rake -j8)
ls -l "$ROOT/build/host-aot/bin/picoruby"
