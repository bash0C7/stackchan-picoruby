#!/usr/bin/env bash
# Generate the suppify gem from aot/kernels/stackchan_aot.rb and build a host
# picoruby VM that carries it next to the C gem, for bench/aot_ab.rb.
#
#   SPINEL=<spinel>/bin/spinel SPINEL_LIB=<spinel>/lib SUPPIFY=<suppify checkout> tools/aot_host_vm.sh
#   build/host-aot/bin/picoruby bench/aot_ab.rb
#
# Measured with suppify c461121 + spinel 4a28d45. The pair pinned by
# R2P2-darwin (suppify 8d299a4 + spinel d0feb62) rejects these kernels:
# suppify 8d299a4 does not strip spinel's `static inline`.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${SPINEL:?set SPINEL to the spinel binary}"
: "${SPINEL_LIB:?set SPINEL_LIB to spinel/lib}"
: "${SUPPIFY:?set SUPPIFY to a suppify checkout}"
PICORUBY_ROOT=${PICORUBY_ROOT:-$ROOT/vendor/R2P2-ESP32/components/picoruby-esp32/picoruby}

mkdir -p "$ROOT/build/aot"
rm -rf "$ROOT/build/aot/picoruby-stackchan_aot"
(cd "$ROOT/aot/kernels" && SPINEL="$SPINEL" SPINEL_LIB="$SPINEL_LIB" \
  ruby -I "$SUPPIFY/lib" "$SUPPIFY/suppify.rb" stackchan_aot.rb -o stackchan_aot -t picoruby -d "$ROOT/build/aot")
# picoruby's object rule keys on mtime, so a regenerated gem needs a clean build dir.
rm -rf "$ROOT/build/host-aot"
(cd "$PICORUBY_ROOT" && MRUBY_CONFIG="$ROOT/build_config/picoruby-aot-host.rb" MRUBY_BUILD_DIR="$ROOT/build" rake -j8)
ls -l "$ROOT/build/host-aot/bin/picoruby"
