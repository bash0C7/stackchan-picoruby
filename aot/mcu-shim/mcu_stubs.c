/* newlib (ESP-IDF の libc) が持たない signal / sigaction の最小実装 (tools/aot/prepare_mcu.sh が src/ にコピーする)。
 * 参照元は sp_gc.c (sp_gc_debug_env / sp_gc_fault_report) と sp_alloc.c (sp_alloc_report_boot)。どれも
 * SPINEL_GC_DEBUG / SPINEL_ALLOC_REPORT のような環境変数で有効になるデバッグ経路で、MCU では有効にならない。
 * 実測: これらが無いと link が `undefined reference to 'signal'` (4 箇所) / `'sigaction'` (2 箇所) で落ちる。
 * weak なので、IDF 側に実体があってもぶつからない。 */
#include <errno.h>
#include <signal.h>
#include <sys/stat.h>

__attribute__((weak)) void (*signal(int sig, void (*handler)(int)))(int) {
  (void)sig; (void)handler;
  return SIG_ERR;
}

__attribute__((weak)) int sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
  (void)sig; (void)act; (void)old;
  errno = ENOSYS;
  return -1;
}

/* ESP-IDF の newlib は lstat を持たない (symlink が無い)。sp_cold.c の File.symlink? / Dir walk が参照する。無いと link が `undefined reference to lstat` で落ちる。 */
__attribute__((weak)) int lstat(const char *path, struct stat *st) { (void)path; (void)st; errno = ENOSYS; return -1; }

