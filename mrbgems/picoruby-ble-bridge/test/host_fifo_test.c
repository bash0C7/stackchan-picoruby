/*
 * Host unit test for ble_bridge_fifo.c (the portable, thread-safe FIFO).
 *
 * Substitutes counting allocators + a pthread lock for the port-provided
 * primitives, then runs 2 producer threads (writes + events) concurrently
 * with 1 consumer to surface any lost/dup/corrupt node or buffer leak — the
 * thread-safety property the on-device reboot fix depends on.
 *
 * Build & run:
 *   cc -std=c11 -pthread -Wall -Wextra -O2 \
 *     mrbgems/picoruby-ble-bridge/test/host_fifo_test.c -o /tmp/ble_bridge_fifo_test \
 *     && /tmp/ble_bridge_fifo_test
 */
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>

static pthread_mutex_t alloc_lock = PTHREAD_MUTEX_INITIALIZER;
static long live_allocs = 0, total_allocs = 0, total_frees = 0;

static void *counting_malloc(size_t n) {
  pthread_mutex_lock(&alloc_lock);
  total_allocs++; live_allocs++;
  pthread_mutex_unlock(&alloc_lock);
  return malloc(n);
}
static void counting_free(void *p) {
  if (!p) return;
  pthread_mutex_lock(&alloc_lock);
  total_frees++; live_allocs--;
  pthread_mutex_unlock(&alloc_lock);
  free(p);
}

#define BLE_BRIDGE_MALLOC(n) counting_malloc(n)
#define BLE_BRIDGE_FREE(p)   counting_free(p)

/* Port-provided lock — a plain pthread mutex here. */
static pthread_mutex_t fifo_lock = PTHREAD_MUTEX_INITIALIZER;
void ble_bridge_lock(void)   { pthread_mutex_lock(&fifo_lock); }
void ble_bridge_unlock(void) { pthread_mutex_unlock(&fifo_lock); }
void ble_bridge_port_init(void) { /* lock is static-initialized here */ }

#include "../src/ble_bridge_fifo.c"

#define N 20000
#define WRITE_HANDLE 7
#define WRITE_SIZE 16
#define EVENT_SIZE 8

static long pushed_w = 0, pushed_e = 0;
static volatile sig_atomic_t producers_done = 0;

static void *producer_writes(void *arg) {
  (void)arg;
  uint8_t buf[WRITE_SIZE];
  for (int i = 0; i < N; i++) {
    memset(buf, (i & 0xff), sizeof(buf));
    if (ble_bridge_write_push(WRITE_HANDLE, buf, sizeof(buf)) == 0) pushed_w++;
  }
  return NULL;
}
static void *producer_events(void *arg) {
  (void)arg;
  uint8_t buf[EVENT_SIZE];
  for (int i = 0; i < N; i++) {
    memset(buf, (i & 0xff), sizeof(buf));
    if (ble_bridge_event_push(buf, sizeof(buf)) == 0) pushed_e++;
  }
  return NULL;
}

static long got_w = 0, got_e = 0;

static void *consumer(void *arg) {
  (void)arg;
  for (;;) {
    uint8_t *d; uint16_t s; int progressed = 0;
    while (ble_bridge_write_pop(WRITE_HANDLE, &d, &s) == 1) {
      assert(s == WRITE_SIZE);
      ble_bridge_free(d); got_w++; progressed = 1;
    }
    while (ble_bridge_event_pop(&d, &s) == 1) {
      assert(s == EVENT_SIZE);
      ble_bridge_free(d); got_e++; progressed = 1;
    }
    /* After producers are done, one full sweep with nothing left = drained. */
    if (producers_done && !progressed) break;
    if (!progressed) sched_yield();
  }
  return NULL;
}

int main(void) {
  pthread_t pw, pe, cons;
  pthread_create(&cons, NULL, consumer, NULL);
  pthread_create(&pw, NULL, producer_writes, NULL);
  pthread_create(&pe, NULL, producer_events, NULL);

  pthread_join(pw, NULL);
  pthread_join(pe, NULL);
  producers_done = 1;          /* no more pushes can happen after both join */
  pthread_join(cons, NULL);

  int ok = 1;
  printf("pushed_w=%ld got_w=%ld dropped_w=%u\n", pushed_w, got_w, ble_bridge_write_dropped());
  printf("pushed_e=%ld got_e=%ld dropped_e=%u\n", pushed_e, got_e, ble_bridge_event_dropped());
  printf("allocs=%ld frees=%ld live=%ld\n", total_allocs, total_frees, live_allocs);

  if (got_w != pushed_w) { printf("FAIL: write count mismatch\n"); ok = 0; }
  if (got_e != pushed_e) { printf("FAIL: event count mismatch\n"); ok = 0; }
  if (live_allocs != 0)  { printf("FAIL: leak (live != 0)\n"); ok = 0; }
  if (total_allocs != total_frees) { printf("FAIL: alloc/free imbalance\n"); ok = 0; }

  /* reset must free any residue and leave no leak (exercise the disconnect path) */
  ble_bridge_write_push(WRITE_HANDLE, (const uint8_t *)"abc", 3);
  ble_bridge_event_push((const uint8_t *)"xy", 2);
  ble_bridge_reset();
  if (live_allocs != 0) { printf("FAIL: reset leaked\n"); ok = 0; }

  printf(ok ? "ALL PASS\n" : "FAILED\n");
  return ok ? 0 : 1;
}
