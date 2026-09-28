#!/usr/bin/env bash
# Compile every TU of a prepared gem (tools/aot/prepare_mcu.sh) with the
# ESP32-S3 gcc and -fsyntax-only: a missing shim shows up in seconds instead of
# in a firmware build. XTENSA_GCC overrides the compiler.
#
#   tools/aot/syntax_check_mcu.sh build/aot/esp32/gems/picoruby-stackchan_aot
set -uo pipefail

gem=$(cd "${1:?usage: tools/aot/syntax_check_mcu.sh <gem dir>}" && pwd)
name=$(basename "$gem"); name=${name#picoruby-}
cc=${XTENSA_GCC:-$(ls "$HOME"/.espressif/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin/xtensa-esp32s3-elf-gcc | tail -1)}
archflags="-mlongcalls"
flags=$(cat "$gem/mcu-flags.txt")
rc=0
for f in "$gem"/src/*.c; do
  b=$(basename "$f" .c)
  # mrbgem.rake が除外する TU は見ない
  grep -qx "$b" "$gem/mcu-excluded.txt" && continue
  # binding.c は mruby.h が要る (libmruby の rake が include path を持つ) ので syntax check の対象外
  [ "$b" = binding ] && continue
  out=$($cc $archflags -fsyntax-only -Os -I"$gem/src" -I"$gem/include" -include "$gem/src/${name}_prelude.h" $flags "$f" 2>&1)
  if [ $? -ne 0 ]; then
    echo "== $b"; echo "$out" | grep -E "error|fatal" | head -40; rc=1
  fi
done
echo "syntax_check exit=$rc"
exit $rc
