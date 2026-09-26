#!/usr/bin/env bash
# suppify が生成した mrbgem (build/aot/picoruby-<name>/) を、MCU (ESP32-S3、xtensa、newlib、32bit) の
# firmware に載せられるように、機械的・冪等に手当てする。suppify を回し直したら、これも回し直す。
# 対象 (2 番目の引数か env AOT_MCU_TARGET): esp32 (既定。xtensa) / rp2040 (Pico 2 W の RP2350、Cortex-M33、arm-none-eabi newlib、32bit)。
# 手当ての中身は両方で同じ (どちらも 32bit の newlib)。対象は mcu-target.txt に残り、tools/aot/syntax_check_mcu.sh が compiler を選ぶのに読む。
#
#   tools/aot/prepare_mcu.sh build/aot/esp32/gems/picoruby-stackchan_aot [esp32|rp2040]
#
# 手当てと根拠 (aot/README.md に詳細。値は env AOT_MCU_* で上書きできる):
#  (a) sp_gc.h / sp_alloc.c の無条件 #define の静的表 (REMEMBERED_MAX / PINNED_MAX / ALLOC_NAMES / STR_SHAPE_MAX) を
#      #ifndef 付きに書き換える。-D が効かず、静的表が合計 350 KB 超あって dram0 が溢れるため。
#  (b) sp_slab.c を aot/mcu-shim/sp_slab_malloc.c (malloc 版) に差し替える。
#      元は mmap / MAP_NORESERVE 必須で、64bit ポインタ前提の static assert が 32bit で落ちるため。
#  (c) sp_net / sp_process / sp_process_status を objs.reject! で除外する (POSIX 依存で compile できず、到達不能)。
#      他の TU は aot/mcu-shim/ の shim ヘッダで通す。shim は gem 内 (mcu-shim/) にコピーして自己完結にする。
#      newlib に無い signal / sigaction は mcu_stubs.c (weak) を src/ に足す。
#  (c2) sp_fiber.c の stack overflow 報告 (SIGSEGV/SIGBUS の sigaction + sigaltstack + siginfo_t.si_addr) を SP_NO_FIBER_FAULT_HANDLER で
#      無効にする。newlib は SA_SIGINFO / SA_ONSTACK / sa_sigaction / si_addr を持たず、MCU には fault signal も無い。host OS 専用の診断で、
#      kernel は Fiber を使わないので落としても実行に影響しない (無効時の sp_fiber_fault_arm は空。sp_fiber_worker_init が呼ぶだけ)。
#  (d) mrbgem.rake に cc.flags を足す: 表のサイズの -D、shim の include path、-include mcu_compat.h (__int128 の代替)。
#
# 出力 (gem 内): mcu-shim/ (shim のコピー)、mcu-flags.txt (足した flag)、mcu-excluded.txt (除外した TU)。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
usage="usage: tools/aot/prepare_mcu.sh <generated gem dir> [esp32|rp2040]"
gem=$(cd "${1:?$usage}" && pwd)
TARGET=${2:-${AOT_MCU_TARGET:-esp32}}
case "$TARGET" in esp32|rp2040) ;; *) echo "$usage" >&2; exit 2 ;; esac
src="$gem/src"
[ -f "$src/sp_gc.h" ] && [ -f "$src/sp_slab.c" ] || { echo "not a suppify-generated gem: $gem" >&2; exit 2; }

# 縮小後の値 (根拠は aot/README.md)。
# GC root 表 (STACK_MAX) だけは溢れると無言で root を落とす (UAF)。remembered / pinned は溢れると full GC に落ちるだけで安全。
STACK_MAX=${AOT_MCU_GC_STACK_MAX:-256}
REMEMBERED_MAX=${AOT_MCU_GC_REMEMBERED_MAX:-256}
PINNED_MAX=${AOT_MCU_GC_PINNED_MAX:-128}
ALLOC_STATS=${AOT_MCU_ALLOC_STATS:-16}       # allocation report の統計表 (診断だけ)
EXC_STACK_MAX=${AOT_MCU_EXC_STACK_MAX:-16}   # begin/rescue の同時 nest 深さ。超えると "stack level too deep" で exit(1) (無言ではない)
ALLOC_NAMES=${AOT_MCU_ALLOC_NAMES:-16}       # 同 型名表 (診断だけ)
STR_SHAPE_MAX=${AOT_MCU_STR_SHAPE_MAX:-16}   # [gcph] 診断の sweep sample ring (診断だけ)
DYN_SYMS_MAX=${AOT_MCU_DYN_SYMS_MAX:-64}     # 実行時に intern する Symbol の表。AOT の入口は使わない
GC_THRESHOLD_INIT=${AOT_MCU_GC_THRESHOLD_INIT:-16384}       # obj heap の初回 GC trigger (bytes)
STR_THRESHOLD_INIT=${AOT_MCU_STR_THRESHOLD_INIT:-8192}       # string heap の初回 trigger
STR_OLD_THRESHOLD_INIT=${AOT_MCU_STR_OLD_THRESHOLD_INIT:-32768}   # string old 世代の major trigger
EXCLUDED="sp_net sp_process sp_process_status"
defs="SP_GC_STACK_MAX=$STACK_MAX SP_GC_REMEMBERED_MAX=$REMEMBERED_MAX SP_GC_PINNED_MAX=$PINNED_MAX SP_ALLOC_STATS=$ALLOC_STATS SP_EXC_STACK_MAX=$EXC_STACK_MAX SP_ALLOC_NAMES=$ALLOC_NAMES SP_STR_SHAPE_MAX=$STR_SHAPE_MAX SP_DYN_SYMS_MAX=$DYN_SYMS_MAX SP_GC_THRESHOLD_INIT=$GC_THRESHOLD_INIT SP_STR_THRESHOLD_INIT=$STR_THRESHOLD_INIT SP_STR_OLD_THRESHOLD_INIT=$STR_OLD_THRESHOLD_INIT SP_NO_FIBER_FAULT_HANDLER=1"

# (a) 無条件の #define を #ifndef 付きにする (冪等: 既に #ifndef ならそのまま)。<file>:<macro>:<元の値>
for spec in "sp_gc.h:SP_GC_REMEMBERED_MAX:65536" "sp_gc.h:SP_GC_PINNED_MAX:16384" "sp_alloc.c:SP_ALLOC_NAMES:512" "sp_alloc.c:SP_STR_SHAPE_MAX:8192" "spinel_rt.h:SP_EXC_STACK_MAX:64"; do
  IFS=: read -r f m v <<< "$spec"
  if ! grep -q "^#ifndef $m\$" "$src/$f"; then
    perl -0pi -e "s/^#define $m $v\$/#ifndef $m\n#define $m $v\n#endif/m" "$src/$f"
    grep -q "^#ifndef $m\$" "$src/$f" || { echo "could not patch $m in $f (spinel の版が変わった?)" >&2; exit 3; }
  fi
done

# (a2) GC の初期 trigger (既定 256 KB / 256 KB / 1 MB) は MCU の動的 heap (約 110 KB) より大きく、
# 回収が始まる前に malloc が尽きて sp_oom_die ("unhandled exception: out of memory") になる。マクロにして -D で下げる。
if ! grep -q "SP_GC_THRESHOLD_INIT" "$src/sp_alloc.c"; then
  perl -0pi -e 's/^size_t sp_str_threshold = 256 \* 1024;\nsize_t sp_str_threshold_init = 256 \* 1024;/#ifndef SP_STR_THRESHOLD_INIT\n#define SP_STR_THRESHOLD_INIT (256 * 1024)\n#endif\nsize_t sp_str_threshold = SP_STR_THRESHOLD_INIT;\nsize_t sp_str_threshold_init = SP_STR_THRESHOLD_INIT;/m;
           s/^size_t sp_gc_threshold = 256 \* 1024;\nsize_t sp_gc_threshold_init = 256 \* 1024;/#ifndef SP_GC_THRESHOLD_INIT\n#define SP_GC_THRESHOLD_INIT (256 * 1024)\n#endif\nsize_t sp_gc_threshold = SP_GC_THRESHOLD_INIT;\nsize_t sp_gc_threshold_init = SP_GC_THRESHOLD_INIT;/m;
           s/^size_t sp_str_old_threshold = 1024 \* 1024;\nsize_t sp_str_old_threshold_init = 1024 \* 1024;/#ifndef SP_STR_OLD_THRESHOLD_INIT\n#define SP_STR_OLD_THRESHOLD_INIT (1024 * 1024)\n#endif\nsize_t sp_str_old_threshold = SP_STR_OLD_THRESHOLD_INIT;\nsize_t sp_str_old_threshold_init = SP_STR_OLD_THRESHOLD_INIT;/m' "$src/sp_alloc.c"
  [ "$(grep -c "_THRESHOLD_INIT;" "$src/sp_alloc.c")" -ge 6 ] || { echo "could not patch GC thresholds in sp_alloc.c (spinel の版が変わった?)" >&2; exit 3; }
fi

# (c2) sp_fiber.c の stack overflow 報告を #ifndef SP_NO_FIBER_FAULT_HANDLER で囲む (冪等)。無効時は sp_fiber_fault_arm を空にする。
if ! grep -q "SP_NO_FIBER_FAULT_HANDLER" "$src/sp_fiber.c"; then
  perl -0pi -e 's/^#include <signal.h>\nstatic void sp_fiber_fault_write\(/#ifndef SP_NO_FIBER_FAULT_HANDLER\n#include <signal.h>\nstatic void sp_fiber_fault_write(/m;
                 s/^  installed = 1;\n\}\nvoid sp_fiber_worker_init\(void\) \{/  installed = 1;\n}\n#else\nstatic void sp_fiber_fault_arm(void) {}\n#endif\nvoid sp_fiber_worker_init(void) {/m' "$src/sp_fiber.c"
  [ "$(grep -c "SP_NO_FIBER_FAULT_HANDLER\|^#endif$" "$src/sp_fiber.c")" -ge 1 ] && grep -q "^#ifndef SP_NO_FIBER_FAULT_HANDLER" "$src/sp_fiber.c" && grep -q "^static void sp_fiber_fault_arm(void) {}" "$src/sp_fiber.c" \
    || { echo "could not patch the fault handler in sp_fiber.c (spinel の版が変わった?)" >&2; exit 3; }
fi

# (b) sp_slab.c を malloc 版に。(c) shim と stub をコピー。
cp "$ROOT/aot/mcu-shim/sp_slab_malloc.c" "$src/sp_slab.c"
cp "$ROOT/aot/mcu-shim/mcu_stubs.c" "$src/mcu_stubs.c"
rm -rf "$gem/mcu-shim"
mkdir -p "$gem/mcu-shim"
cp -R "$ROOT/aot/mcu-shim/." "$gem/mcu-shim/"
rm -f "$gem/mcu-shim/sp_slab_malloc.c" "$gem/mcu-shim/mcu_stubs.c"

# (d) flags (mcu-flags.txt は tools/aot/syntax_check_mcu.sh が読み、mrbgem.rake の block と同じ内容)
dflags=""; rakeflags=""
for d in $defs; do dflags="$dflags -D$d"; rakeflags="$rakeflags << \"-D$d\""; done
echo "${dflags# } -I$gem/mcu-shim -include $gem/mcu-shim/mcu_compat.h" > "$gem/mcu-flags.txt"
echo "$TARGET" > "$gem/mcu-target.txt"
: > "$gem/mcu-excluded.txt"
for x in $EXCLUDED; do echo "$x" >> "$gem/mcu-excluded.txt"; done

# mrbgem.rake: 既存の手当て block を消してから足す (冪等)
perl -0pi -e 's/  # --- aot_prepare_mcu begin ---.*?# --- aot_prepare_mcu end ---\n//s' "$gem/mrbgem.rake"
perl -0pi -e 's/\nend\s*\z/\n__MCU_BLOCK__\nend\n/' "$gem/mrbgem.rake"
block=$(cat <<EOF
  # --- aot_prepare_mcu begin ---
  # tools/aot/prepare_mcu.sh が足した block (aot/README.md)。
  spec.objs.reject! { |o| o =~ /(sp_net|sp_process_status|sp_process)\.(o|obj)\$/ }
  spec.cc.flags$rakeflags
  spec.cc.include_paths << "#{dir}/mcu-shim"
  spec.cc.flags << "-include #{dir}/mcu-shim/mcu_compat.h"
  # --- aot_prepare_mcu end ---
EOF
)
BLOCK="$block" perl -0pi -e 's/__MCU_BLOCK__/$ENV{BLOCK}/' "$gem/mrbgem.rake"
grep -q "aot_prepare_mcu begin" "$gem/mrbgem.rake" || { echo "mrbgem.rake patch failed" >&2; exit 3; }
echo "prepared: $gem [$TARGET] ($defs)"
