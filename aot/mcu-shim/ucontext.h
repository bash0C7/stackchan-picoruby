/* ucontext は ESP-IDF に無い。sp_fiber_ctx.h の portable fallback が型と 3 関数を要る。宣言だけ (Fiber は入口から到達しない)。 */
#ifndef MCU_SHIM_UCONTEXT_H
#define MCU_SHIM_UCONTEXT_H
#include <stddef.h>
typedef struct { void *ss_sp; size_t ss_size; int ss_flags; } mcu_stack_t;
typedef struct ucontext { struct ucontext *uc_link; mcu_stack_t uc_stack; char uc_regs[128]; } ucontext_t;
int getcontext(ucontext_t *);
void makecontext(ucontext_t *, void (*)(void), int, ...);
int swapcontext(ucontext_t *, const ucontext_t *);
#endif
