/*
 * VM dispatcher for picoruby-ble-bridge.
 *
 * The portable FIFO lives in ble_bridge_fifo.c (also compiled into libmruby).
 * The ESP32 lock + linker-wrap interposition live in
 * ports/esp32/ble_bridge_port.c (compiled into the picoruby-esp32 IDF
 * component, where FreeRTOS headers are available). Only the mruby binding is
 * dispatched here. This project builds PICORB_VM_MRUBY only.
 */
#if defined(PICORB_VM_MRUBY)
#include "mruby/ble_bridge.c"
#endif
