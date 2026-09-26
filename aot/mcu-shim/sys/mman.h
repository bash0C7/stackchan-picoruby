/* mmap 系は ESP-IDF の newlib に無い。宣言だけ (sp_fiber.c の Fiber stack、sp_iobuffer.c の IO::Buffer.map 用。入口から到達しなければ --gc-sections で消える)。 */
#ifndef MCU_SHIM_SYS_MMAN_H
#define MCU_SHIM_SYS_MMAN_H
#include <stddef.h>
#include <sys/types.h>
#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define MAP_SHARED 1
#define MAP_PRIVATE 2
#define MAP_ANONYMOUS 0x20
#define MAP_ANON MAP_ANONYMOUS
#define MAP_NORESERVE 0
#define MAP_STACK 0
#define MAP_FAILED ((void *)-1)
#define MADV_DONTNEED 4
void *mmap(void *, size_t, int, int, int, off_t);
int munmap(void *, size_t);
int mprotect(void *, size_t, int);
int madvise(void *, size_t, int);
#endif
