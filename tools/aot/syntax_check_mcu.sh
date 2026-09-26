#!/usr/bin/env bash
# 手当て済みの生成 gem (tools/aot/prepare_mcu.sh の後) の全 TU を、対象の gcc で -fsyntax-only する。
# firmware を build せずに、shim の不足 (無いヘッダ、型) を数秒で洗い出すための道具。
#
#   tools/aot/syntax_check_mcu.sh build/aot/esp32/gems/picoruby-stackchan_aot [esp32|rp2040]
#
# 対象は 2 番目の引数、無ければ env AOT_MCU_TARGET、無ければ aot_prepare_mcu.sh が gem に残した mcu-target.txt、無ければ esp32。
#   esp32  : ESP32-S3 の xtensa gcc (ESP-IDF の install 先。env XTENSA_GCC で上書き)
#   rp2040 : Pico 2 W (RP2350、Cortex-M33) の arm-none-eabi-gcc (PATH、または env ARM_GCC で上書き)
# gem の mrbgem.rake が足した cc.flags と同じ flag (MCU_FLAGS) を aot_prepare_mcu.sh の出力 (mcu-flags.txt) から読む。
set -uo pipefail

gem=$(cd "${1:?usage: tools/aot/syntax_check_mcu.sh <gem dir> [esp32|rp2040]}" && pwd)
name=$(basename "$gem"); name=${name#picoruby-}
target=${2:-${AOT_MCU_TARGET:-$(cat "$gem/mcu-target.txt" 2>/dev/null || echo esp32)}}
case "$target" in
  esp32)
    cc=${XTENSA_GCC:-$(ls "$HOME"/.espressif/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin/xtensa-esp-elf-gcc | tail -1)}
    archflags="-mlongcalls"
    ;;
  rp2040)
    cc=${ARM_GCC:-$(command -v arm-none-eabi-gcc || true)}
    [ -n "$cc" ] || { echo "arm-none-eabi-gcc not found (PATH or env ARM_GCC)" >&2; exit 2; }
    archflags="-mcpu=cortex-m33 -mthumb"
    ;;
  *) echo "unknown target: $target (esp32 | rp2040)" >&2; exit 2 ;;
esac
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
echo "syntax_check exit=$rc target=$target"
exit $rc
