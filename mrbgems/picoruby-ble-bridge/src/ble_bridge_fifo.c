/*
 * ble_bridge_fifo.c — portable, thread-safe FIFO for picoruby-ble-bridge.
 * See ble_bridge.h. Compiled into libmruby (no IDF deps); host-testable.
 *
 * Allocation goes through BLE_BRIDGE_MALLOC/FREE so the host unit test can
 * substitute counting allocators for leak detection. Defaults to libc, whose
 * heap is thread-safe on ESP32 (newlib) and the host.
 */
#include "../include/ble_bridge.h"
#include <stdlib.h>
#include <string.h>

#ifndef BLE_BRIDGE_MALLOC
#define BLE_BRIDGE_MALLOC(n) malloc(n)
#endif
#ifndef BLE_BRIDGE_FREE
#define BLE_BRIDGE_FREE(p) free(p)
#endif

typedef struct ble_wnode {
  uint16_t att_handle;
  uint16_t size;
  uint8_t *data;
  struct ble_wnode *next;
} ble_wnode_t;

typedef struct ble_enode {
  uint16_t size;
  uint8_t *data;
  struct ble_enode *next;
} ble_enode_t;

static ble_wnode_t *w_head = NULL, *w_tail = NULL;
static uint32_t w_count = 0, w_dropped = 0;
static ble_enode_t *e_head = NULL, *e_tail = NULL;
static uint32_t e_count = 0, e_dropped = 0;

void
ble_bridge_reset(void)
{
  ble_wnode_t *w, *wn;
  ble_enode_t *e, *en;
  ble_bridge_lock();
  w = w_head; w_head = w_tail = NULL; w_count = 0;
  e = e_head; e_head = e_tail = NULL; e_count = 0;
  ble_bridge_unlock();
  /* free outside the lock */
  for (; w; w = wn) { wn = w->next; BLE_BRIDGE_FREE(w->data); BLE_BRIDGE_FREE(w); }
  for (; e; e = en) { en = e->next; BLE_BRIDGE_FREE(e->data); BLE_BRIDGE_FREE(e); }
}

int
ble_bridge_write_push(uint16_t att_handle, const uint8_t *data, uint16_t size)
{
  if (att_handle == 0 || size == 0 || data == NULL) return -1;
  uint8_t *buf = (uint8_t *)BLE_BRIDGE_MALLOC(size);
  if (!buf) return -1;
  memcpy(buf, data, size);
  ble_wnode_t *n = (ble_wnode_t *)BLE_BRIDGE_MALLOC(sizeof(*n));
  if (!n) { BLE_BRIDGE_FREE(buf); return -1; }
  n->att_handle = att_handle; n->size = size; n->data = buf; n->next = NULL;

  ble_bridge_lock();
  if (w_count >= BLE_BRIDGE_WRITE_MAX) {
    w_dropped++;
    ble_bridge_unlock();
    BLE_BRIDGE_FREE(buf); BLE_BRIDGE_FREE(n);
    return -1;
  }
  if (w_tail) w_tail->next = n; else w_head = n;
  w_tail = n; w_count++;
  ble_bridge_unlock();
  return 0;
}

int
ble_bridge_write_pop(uint16_t att_handle, uint8_t **out_data, uint16_t *out_size)
{
  ble_wnode_t *got = NULL, *prev = NULL, *p;
  ble_bridge_lock();
  for (p = w_head; p; prev = p, p = p->next) {
    if (p->att_handle == att_handle) {
      if (prev) prev->next = p->next; else w_head = p->next;
      if (w_tail == p) w_tail = prev;
      got = p; w_count--;
      break;
    }
  }
  ble_bridge_unlock();
  if (!got) return 0;
  *out_data = got->data;
  *out_size = got->size;
  BLE_BRIDGE_FREE(got);            /* node only; data ownership goes to caller */
  return 1;
}

int
ble_bridge_event_push(const uint8_t *data, uint16_t size)
{
  if (size == 0 || data == NULL) return -1;
  uint8_t *buf = (uint8_t *)BLE_BRIDGE_MALLOC(size);
  if (!buf) return -1;
  memcpy(buf, data, size);
  ble_enode_t *n = (ble_enode_t *)BLE_BRIDGE_MALLOC(sizeof(*n));
  if (!n) { BLE_BRIDGE_FREE(buf); return -1; }
  n->size = size; n->data = buf; n->next = NULL;

  ble_bridge_lock();
  if (e_count >= BLE_BRIDGE_EVENT_MAX) {
    e_dropped++;
    ble_bridge_unlock();
    BLE_BRIDGE_FREE(buf); BLE_BRIDGE_FREE(n);
    return -1;
  }
  if (e_tail) e_tail->next = n; else e_head = n;
  e_tail = n; e_count++;
  ble_bridge_unlock();
  return 0;
}

int
ble_bridge_event_pop(uint8_t **out_data, uint16_t *out_size)
{
  ble_enode_t *got = NULL;
  ble_bridge_lock();
  if (e_head) {
    got = e_head;
    e_head = e_head->next;
    if (e_tail == got) e_tail = NULL;
    e_count--;
  }
  ble_bridge_unlock();
  if (!got) return 0;
  *out_data = got->data;
  *out_size = got->size;
  BLE_BRIDGE_FREE(got);
  return 1;
}

void ble_bridge_free(void *p) { BLE_BRIDGE_FREE(p); }

uint32_t ble_bridge_write_dropped(void) { return w_dropped; }
uint32_t ble_bridge_event_dropped(void) { return e_dropped; }
