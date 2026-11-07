#!/usr/bin/env bash
set -uo pipefail

gem=$(cd "${1:?usage: tools/aot/syntax_check_mcu.sh <gem dir>}" && pwd)
cc=${XTENSA_GCC:-$(ls "${IDF_TOOLS_PATH:-$HOME/.espressif}"/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin/xtensa-esp32s3-elf-gcc | tail -1)}
[ -d "$gem/src/newlib" ] || { echo "not a suppify gem generated with --cc for a newlib board: $gem" >&2; exit 2; }
read -r -a gemflags <<< "$(ruby -e '
  rake = File.read(ARGV[0])
  dir = File.dirname(ARGV[0])
  newlib = "#{dir}/src/newlib"
  incs = rake.scan(/spec\.cc\.include_paths(?:\.(?:concat|unshift)\((.*?)\)| << (.*))$/).flat_map { eval("[#{_1.compact[0]}]").flatten }
  defs = rake.scan(/spec\.cc\.defines\.concat\((.*?)\)$/).flat_map { eval(_1[0]) }
  flags = rake.scan(/spec\.cc\.flags\.concat\((.*?)\)$/).flat_map { eval(_1[0]) }
  puts((incs.map { "-I#{_1}" } + defs.map { "-D#{_1}" } + flags).join(" "))
' "$gem/mrbgem.rake")"
flags=(-mlongcalls -fsyntax-only -Os -include "$gem/src/newlib/sp_newlib_config.h"
       -I"$gem/include" "${gemflags[@]}")
rc=0
for f in "$gem"/src/*.c "$gem"/src/instances/*_glue.c; do
  [ "$(basename "$f")" = binding.c ] && continue
  extra=()
  case "$f" in "$gem"/src/instances/*) extra=(-I"$gem/src") ;; esac
  out=$($cc "${flags[@]}" "${extra[@]}" "$f" 2>&1)
  if [ $? -ne 0 ]; then
    echo "== $(basename "$f")"; echo "$out" | grep -E "error|fatal" | head -40; rc=1
  fi
done
echo "syntax_check exit=$rc"
exit $rc
