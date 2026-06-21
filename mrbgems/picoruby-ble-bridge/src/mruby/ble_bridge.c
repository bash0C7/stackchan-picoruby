/*
 * picoruby-ble-bridge mruby binding (BLEBridge module).
 *
 * Drains the thread-safe C FIFO (ble_bridge_fifo.c) that the BTstack task
 * filled via __wrap_BLE_write_data, building the mruby String HERE on the main
 * task. This replaces BLE#pop_write_value for inbound NUS data, removing all
 * mruby access from the BTstack-task callback (see ports/esp32/ble_bridge_port.c).
 */
#include <mruby.h>
#include <mruby/string.h>
#include "../../include/ble_bridge.h"

static mrb_value
mrb_ble_bridge_init(mrb_state *mrb, mrb_value self)
{
  (void)mrb; (void)self;
  ble_bridge_port_init();
  return mrb_nil_value();
}

static mrb_value
mrb_ble_bridge_pop_write(mrb_state *mrb, mrb_value self)
{
  (void)self;
  mrb_int handle;
  mrb_get_args(mrb, "i", &handle);
  uint8_t *data;
  uint16_t size;
  if (ble_bridge_write_pop((uint16_t)handle, &data, &size) != 1) {
    return mrb_nil_value();
  }
  mrb_value str = mrb_str_new(mrb, (const char *)data, size);
  ble_bridge_free(data);
  return str;
}

static mrb_value
mrb_ble_bridge_pop_event(mrb_state *mrb, mrb_value self)
{
  (void)self;
  uint8_t *data;
  uint16_t size;
  if (ble_bridge_event_pop(&data, &size) != 1) {
    return mrb_nil_value();
  }
  mrb_value str = mrb_str_new(mrb, (const char *)data, size);
  ble_bridge_free(data);
  return str;
}

static mrb_value
mrb_ble_bridge_reset(mrb_state *mrb, mrb_value self)
{
  (void)mrb; (void)self;
  ble_bridge_reset();
  return mrb_nil_value();
}

static mrb_value
mrb_ble_bridge_write_dropped(mrb_state *mrb, mrb_value self)
{
  (void)self;
  return mrb_fixnum_value((mrb_int)ble_bridge_write_dropped());
}

void
mrb_picoruby_ble_bridge_gem_init(mrb_state *mrb)
{
  struct RClass *mod = mrb_define_module(mrb, "BLEBridge");
  mrb_define_module_function(mrb, mod, "init",          mrb_ble_bridge_init,          MRB_ARGS_NONE());
  mrb_define_module_function(mrb, mod, "pop_write",     mrb_ble_bridge_pop_write,     MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, mod, "pop_event",     mrb_ble_bridge_pop_event,     MRB_ARGS_NONE());
  mrb_define_module_function(mrb, mod, "reset",         mrb_ble_bridge_reset,         MRB_ARGS_NONE());
  mrb_define_module_function(mrb, mod, "write_dropped", mrb_ble_bridge_write_dropped, MRB_ARGS_NONE());
}

void
mrb_picoruby_ble_bridge_gem_final(mrb_state *mrb)
{
  (void)mrb;
}
