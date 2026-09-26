/* newlib (ESP-IDF の libc) が持たない signal / sigaction の最小実装 (scripts/aot_prepare_mcu.sh が src/ にコピーする)。
 * 参照元は sp_gc.c (sp_gc_debug_env / sp_gc_fault_report) と sp_alloc.c (sp_alloc_report_boot)。どれも
 * SPINEL_GC_DEBUG / SPINEL_ALLOC_REPORT のような環境変数で有効になるデバッグ経路で、MCU では有効にならない。
 * 実測: これらが無いと link が `undefined reference to 'signal'` (4 箇所) / `'sigaction'` (2 箇所) で落ちる。
 * weak なので、複数の AOT gem が同じ stub を持っても、IDF 側に実体があってもぶつからない。 */
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

/* arm-none-eabi と ESP-IDF の newlib は lstat を持たない (symlink が無い)。sp_cold.c の File.symlink? / Dir walk が参照する。link が `undefined reference to `lstat'` で落ちた (実測)。 */
__attribute__((weak)) int lstat(const char *path, struct stat *st) { (void)path; (void)st; errno = ENOSYS; return -1; }

#ifdef __arm__
/* arm-none-eabi の newlib に無い POSIX の時計と dirent の最小実装 (aot/mcu-shim/mcu_compat.h、dirent.h と対)。
 * どれも weak の失敗返し。spinel の Time / Process.clock_gettime / Dir は Pico 2 W の bench から到達しない。
 * ESP32 (xtensa) の newlib には実体があるので、この節は arm のときだけ。 */
#include <dirent.h>
#include <time.h>
#include <sys/stat.h>

/* newlib の stat() / lstat 経由の _stat_r が呼ぶ syscall。pico-sdk は _stat を持たず、link が `undefined reference to `_stat'` で落ちた (実測)。 */
__attribute__((weak)) int _stat(const char *path, struct stat *st) { (void)path; (void)st; errno = ENOSYS; return -1; }

__attribute__((weak)) int clock_gettime(clockid_t id, struct timespec *ts) { (void)id; (void)ts; errno = ENOSYS; return -1; }
__attribute__((weak)) int clock_getres(clockid_t id, struct timespec *ts) { (void)id; (void)ts; errno = ENOSYS; return -1; }
__attribute__((weak)) int nanosleep(const struct timespec *req, struct timespec *rem) { (void)req; (void)rem; errno = ENOSYS; return -1; }
__attribute__((weak)) DIR *opendir(const char *path) { (void)path; errno = ENOSYS; return (DIR *)0; }
__attribute__((weak)) DIR *fdopendir(int fd) { (void)fd; errno = ENOSYS; return (DIR *)0; }
__attribute__((weak)) struct dirent *readdir(DIR *d) { (void)d; return (struct dirent *)0; }
__attribute__((weak)) int closedir(DIR *d) { (void)d; return -1; }
__attribute__((weak)) void rewinddir(DIR *d) { (void)d; }
__attribute__((weak)) long telldir(DIR *d) { (void)d; return -1; }
__attribute__((weak)) void seekdir(DIR *d, long pos) { (void)d; (void)pos; }
__attribute__((weak)) int dirfd(DIR *d) { (void)d; errno = ENOSYS; return -1; }
#endif
