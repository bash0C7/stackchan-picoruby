/*
 * ble_bridge.h — thread-safe C bridge for picoruby-ble inbound data.
 *
 * Purpose: keep ALL mruby VM access out of the BTstack run-loop task. The
 * picoruby-ble ESP32 port calls BLE_write_data() from that task on every
 * inbound GATT write; the fork's implementation builds an mruby String and
 * mrb_ary_push()es it there, racing the main-task VM and corrupting the
 * non-thread-safe mruby allocator/GC (StoreProhibited reboot during BLE audio
 * streaming). This bridge is a plain-C, lock-guarded FIFO: the BTstack task
 * only copies bytes in (via __wrap_BLE_write_data, ports/esp32); the mruby
 * String is built later on the main task in BLEBridge.pop_write.
 *
 * The lock primitive is port-provided (extern): a FreeRTOS mutex on ESP32
 * (ports/esp32/ble_bridge_port.c), a pthread mutex in the host unit test. The
 * FIFO logic itself (ble_bridge_fifo.c) is port-agnostic and host-testable.
 *
 * Memory ownership: *_pop transfers ownership of the malloc'd buffer to the
 * caller, which must release it via ble_bridge_free() after building the
 * mruby String.
 */
#ifndef PICORUBY_BLE_BRIDGE_H_
#define PICORUBY_BLE_BRIDGE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bounds so a flooding central cannot drive unbounded malloc if the main task
 * stalls (e.g. during a long blocking playback). Excess is dropped and
 * counted, never silently lost. */
#ifndef BLE_BRIDGE_WRITE_MAX
#define BLE_BRIDGE_WRITE_MAX 1024
#endif
#ifndef BLE_BRIDGE_EVENT_MAX
#define BLE_BRIDGE_EVENT_MAX 32
#endif

/* Port-provided lock (a plain mutex; the bridge never nests acquisitions). */
void ble_bridge_lock(void);
void ble_bridge_unlock(void);

/* Port-provided one-time init: create the lock primitive. Call once on the
 * main task before BLE advertising starts (BLEBridge.init). */
void ble_bridge_port_init(void);

/* Reset all queues (free every pending buffer). Call on disconnect. */
void ble_bridge_reset(void);

/* --- BTstack-task side: copy bytes in, no mruby --- */

/* Enqueue an inbound write for att_handle. Returns 0 on success, -1 on bad
 * args / OOM / queue full (dropped). */
int ble_bridge_write_push(uint16_t att_handle, const uint8_t *data, uint16_t size);

/* Enqueue an HCI/ATT event packet. Returns 0 on success, -1 on OOM / full. */
int ble_bridge_event_push(const uint8_t *data, uint16_t size);

/* --- main-task side: hand bytes out, caller builds the mruby String --- */

/* Pop the oldest queued write for att_handle. On success sets *out_data
 * (malloc'd, caller frees) and *out_size and returns 1; returns 0 if none. */
int ble_bridge_write_pop(uint16_t att_handle, uint8_t **out_data, uint16_t *out_size);

/* Pop the oldest queued event. Same ownership contract. Returns 1 / 0. */
int ble_bridge_event_pop(uint8_t **out_data, uint16_t *out_size);

/* Free a buffer handed out by *_pop, using the bridge's own allocator (so the
 * caller need not know whether it was libc malloc or a substituted one). */
void ble_bridge_free(void *p);

/* Diagnostics (best-effort; reads are not locked). */
uint32_t ble_bridge_write_dropped(void);
uint32_t ble_bridge_event_dropped(void);

#ifdef __cplusplus
}
#endif

#endif /* PICORUBY_BLE_BRIDGE_H_ */
