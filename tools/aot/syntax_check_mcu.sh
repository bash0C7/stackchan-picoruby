#!/usr/bin/env bash
set -uo pipefail

gem=$(cd "${1:?usage: tools/aot/syntax_check_mcu.sh <gem dir>}" && pwd)
cc=${XTENSA_GCC:-$(ls "$HOME"/.espressif/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin/xtensa-esp32s3-elf-gcc | tail -1)}
[ -d "$gem/src/newlib" ] || { echo "not a --newlib suppify gem: $gem" >&2; exit 2; }
read -r -a gemflags <<< "$(ruby -e '
  rake = File.read(ARGV[0])
  defs = rake[/spec\.cc\.defines\.concat\((\[.*?\])\)/, 1]
  flags = rake[/spec\.cc\.flags\.concat\((\[.*?\])\)/, 1]
  puts((eval(defs).map { "-D#{_1}" } + eval(flags)).join(" "))
' "$gem/mrbgem.rake")"
flags=(-mlongcalls -fsyntax-only -Os -I"$gem/src/newlib" -D_DEFAULT_SOURCE -include "$gem/src/newlib/sp_newlib_config.h"
       -I"$gem/src" -I"$gem/include" "${gemflags[@]}")
rc=0
for f in "$gem"/src/*.c "$gem"/src/newlib/sp_newlib.c "$gem"/src/instances/*_glue.c; do
  [ "$(basename "$f")" = binding.c ] && continue
  out=$($cc "${flags[@]}" "$f" 2>&1)
  if [ $? -ne 0 ]; then
    echo "== $(basename "$f")"; echo "$out" | grep -E "error|fatal" | head -40; rc=1
  fi
done
echo "syntax_check exit=$rc"
exit $rc
