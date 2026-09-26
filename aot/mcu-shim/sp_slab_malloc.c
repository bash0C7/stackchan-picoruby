/* sp_slab.c の MCU 向け差し替え (scripts/aot_prepare_mcu.sh が src/sp_slab.c に上書きする)。
 * 元の sp_slab.c は mmap / MAP_NORESERVE で 16 GB (32bit でも 512 MB) を予約する size-class slab で、ESP-IDF と
 * arm-none-eabi newlib に mmap は無く、64bit ポインタ前提の static assert (sp_slab_chunk_is_one_line) が 32bit で落ちる。
 * spinel が文書化している slab off の経路 (全 block が malloc、sp_slab_on = 0) を、環境変数抜きで固定したもの。
 * slab が無いので sp_slab_owns (base = 0, cap = 0) は常に偽で、collector は object を young / old の LIST で管理する
 * (SP_GC_HEAP_PUSH)。bitmap を触る関数 (mark / is_str / sweep_worker など) は slab の block にだけ呼ばれるので、ここでは
 * 何もしない。sp_gc_alloc は元の sp_slab.c にあるので、その単一 thread 版 (sp_gc_alloc_full の #else 側) から slab の
 * 部分を除いたものを持つ。spinel の版が変わって宣言が増えたら、link が `undefined reference to <lib>_sp_slab_*` で落ちる。 */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "sp_gc.h"
#include "sp_alloc.h"

int sp_slab_on = 0;
int sp_slab_verify_on = 0;
uintptr_t sp_slab_base = 0;
size_t sp_slab_cap = 0;
unsigned sp_slab_epoch = 0;
SP_TLS unsigned long sp_slab_frees = 0;
int sp_gc_alloc_fast_ok = 0;
unsigned long long sp_slab_rel_calls = 0, sp_slab_rel_walked = 0, sp_slab_rel_madv = 0;
double sp_slab_rel_madv_t = 0, sp_slab_rel_sort_t = 0;

static void *slab_malloc(size_t need, int zero) {
  void *p = zero ? calloc(1, need) : malloc(need);
  if (!p) sp_oom_die();
  return p;
}

void *sp_slab_alloc_raw(size_t need) { return slab_malloc(need, 0); }
void *sp_slab_alloc(size_t need) { return slab_malloc(need, 1); }
void *sp_slab_alloc_str(size_t need) { return slab_malloc(need, 0); }
void *sp_slab_alloc_obj(size_t need, void (*fin)(void *), void (*scn)(void *)) {
  sp_gc_hdr *h = (sp_gc_hdr *)slab_malloc(need, 1);
  h->finalize = fin; h->scan = scn; h->size = need;
  return h;
}
void sp_slab_free(void *p) { free(p); }

/* the object allocation of the program: the collector's bookkeeping around a malloc (sp_slab.c's single-threaded
   sp_gc_alloc_full without the slab) */
void *sp_gc_alloc(size_t sz, void (*fin)(void *), void (*scn)(void *)) {
  SP_HEAP_LOCK();
  if (!sp_gc_stress_checked) {
    sp_gc_stress_checked = 1;
    const char *e = getenv("SPINEL_GC_STRESS");
    if (e && *e && *e != '0') { SP_GC_CTR_SET(sp_gc_threshold, 2048); sp_gc_threshold_init = 2048; sp_gc_stress_pin = 1; }
  }
  if (SP_GC_CTR_GET(sp_gc_bytes) > sp_gc_threshold) sp_gc_collect_retune();
  size_t need = sizeof(sp_gc_hdr) + sz;
  sp_gc_hdr *h = (sp_gc_hdr *)slab_malloc(need, 1);
  h->finalize = fin; h->scan = scn; h->size = need;
  if (sp_alloc_report_on) sp_alloc_report_count((void *)scn, sz);
  SP_GC_HEAP_PUSH(h); sp_gc_bytes_add(need);
  SP_HEAP_UNLOCK();
  return (char *)h + sizeof(sp_gc_hdr);
}

/* a container payload resized: always a malloc block here */
void *sp_pl_realloc(void *p, size_t newn) {
  if (!p) return sp_slab_alloc_raw(newn);
  void *q = realloc(p, newn);
  if (!q) sp_oom_die();
  return q;
}

/* nothing is a slab block, so none of these has anything to do (the callers test sp_slab_owns first) */
void sp_slab_set_fin(void *h) { (void)h; }
void sp_slab_park(void *h) { (void)h; }
void sp_slab_relive(void *h) { (void)h; }
void sp_slab_pin(const void *p) { (void)p; }
int sp_slab_is_str(const void *p) { (void)p; return 0; }
int sp_slab_is_live(const void *p) { (void)p; return 0; }
int sp_slab_is_old(const void *p) { (void)p; return 0; }
int sp_slab_is_marked(const void *p) { (void)p; return 0; }
void sp_slab_describe(const void *p) { (void)p; }
void sp_slab_verify_all(void) {}
void sp_slab_unmark(const void *p) { (void)p; }
int sp_slab_mark(const void *p, int aging, int *was_young) { (void)p; (void)aging; if (was_young) *was_young = 0; return 0; }
void sp_slab_epoch_flip(void) { sp_slab_epoch = sp_slab_epoch + 1; }
void sp_slab_runs_release(void) {}
void sp_slab_history(const void *p) { (void)p; }
void sp_slab_sweep_worker(int wid, int full, int aging, int (*die)(void *hdr), sp_slab_sweep_stats *st) {
  (void)wid; (void)full; (void)aging; (void)die;
  if (st) memset(st, 0, sizeof *st);
}
void sp_slab_each_object(int young, int old, void (*fn)(void *hdr, void *arg), void *arg) { (void)young; (void)old; (void)fn; (void)arg; }
void sp_slab_each_string(int young, int old, void (*fn)(void *hdr, void *arg), void *arg) { (void)young; (void)old; (void)fn; (void)arg; }
void sp_slab_release(void) {}
void sp_slab_release_worker(int wid) { (void)wid; }
void sp_slab_release_from(int first) { (void)first; }
