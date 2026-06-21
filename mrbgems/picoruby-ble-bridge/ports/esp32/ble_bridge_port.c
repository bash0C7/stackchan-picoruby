/*
 * ble_bridge_port.c — ESP32 port for picoruby-ble-bridge.
 *
 * Compiled into the picoruby-esp32 IDF component (added to its CMakeLists SRCS
 * by the stackchan-picoruby build-time overlay), where FreeRTOS headers and
 * the picoruby-ble symbols are in the same final link.
 *
 * Two responsibilities, both kept OUT of the picoruby-ble fork so that fork
 * stays byte-clean (the StackChan reboot workaround is contained here):
 *
 *  1. Linker --wrap interposition of BLE_write_data. The picoruby-ble ESP32
 *     port (ports/esp32/ble.c att_write_callback) calls BLE_write_data() from
 *     the BTstack run-loop task on every inbound GATT write. The fork builds
 *     an mruby String and mrb_ary_push()es it from THAT task, racing the
 *     main-task VM and corrupting the non-thread-safe mruby heap (the
 *     StoreProhibited reboot during BLE audio streaming). With
 *     -Wl,--wrap=BLE_write_data the call is redirected at link time to
 *     __wrap_BLE_write_data below, which only copies the bytes into the
 *     lock-guarded C FIFO. The original (now __real_BLE_write_data) is never
 *     called — it becomes dead code. The mruby String is built later on the
 *     main task in BLEBridge.pop_write.
 *
 *  2. The port-provided lock the FIFO needs (a FreeRTOS mutex).
 */
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "../../include/ble_bridge.h"

static SemaphoreHandle_t ble_bridge_mutex = NULL;

/* Create the lock once, on the main task, before BLE advertising starts.
 * Inbound writes cannot arrive until a central connects (after advertise),
 * which is after the app has called BLEBridge.init. */
void
ble_bridge_port_init(void)
{
  if (!ble_bridge_mutex) ble_bridge_mutex = xSemaphoreCreateMutex();
}

void
ble_bridge_lock(void)
{
  if (ble_bridge_mutex) xSemaphoreTake(ble_bridge_mutex, portMAX_DELAY);
}

void
ble_bridge_unlock(void)
{
  if (ble_bridge_mutex) xSemaphoreGive(ble_bridge_mutex);
}

/* Interposed for BLE_write_data via -Wl,--wrap=BLE_write_data. Runs on the
 * BTstack run-loop task: copy bytes into the FIFO, touch NO mruby state. */
int
__wrap_BLE_write_data(uint16_t att_handle, const uint8_t *data, uint16_t size)
{
  return ble_bridge_write_push(att_handle, data, size);
}

/* Interposed for BLE_push_event via -Wl,--wrap=BLE_push_event. Same hazard as
 * the write path: the BTstack packet_handler delivers HCI/ATT event packets on
 * the run-loop task, and the fork's BLE_push_event mrb_malloc's there, racing
 * the main-task VM (this corrupts the heap during init, right after the btstack
 * setup semaphore is given, while the main task is still unwinding _init). Copy
 * into the FIFO instead; the main task drains it via BLEBridge.pop_event and
 * builds the String there. */
void
__wrap_BLE_push_event(uint8_t *data, uint16_t size)
{
  ble_bridge_event_push(data, size);
}
