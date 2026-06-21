# ble_race_peripheral.rb
#
# Minimal, hardware-independent reproduction for a cross-thread mruby heap
# corruption in picoruby-ble.
#
# Mechanism: on a multi-core / preemptive port (e.g. the ESP32 BTstack port),
# `att_write_callback` runs on the BTstack run-loop task and calls the shared
# `BLE_write_data` (src/mruby/ble.c), which allocates mruby objects directly on
# the single shared VM (`mrb_str_new` / `mrb_hash_*` / `mrb_ary_*`). Meanwhile
# the Ruby VM runs on a different task (the main task). Two tasks mutate the
# one non-thread-safe mruby allocator / GC concurrently -> heap free-list
# corruption -> a later ordinary allocation faults (Guru Meditation
# StoreProhibited inside the allocator).
#
# This script needs NO LCD / servo / audio / I2C — only picoruby-ble. It uses
# only the shared BLE Ruby API, so it is port-agnostic. Pair it with
# flood_rx.rb (a BLE central that floods write-without-response to the RX char).
#
# Expected (buggy build): Guru Meditation StoreProhibited within seconds, with
#   a backtrace through the mruby allocator (est_malloc / mrb_realloc /
#   mrb_ary_push / mrb_str_new).
# Expected (fixed build):  no crash; `rx_bytes=` climbs indefinitely.

require 'ble'

class BleRacePeripheral < BLE
  AD_TYPE_FLAGS = 0x01
  AD_TYPE_NAME  = 0x09
  AD_FLAGS      = 0x06
  BTSTACK_EVENT_STATE              = 0x60
  HCI_EVENT_DISCONNECTION_COMPLETE = 0x05

  # Nordic UART Service compatible UUIDs (so a NUS-aware central can target it).
  SVC_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x01\x00\x40\x6e"
  RX_UUID  = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x02\x00\x40\x6e"
  RX_PROPS = BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC

  def initialize
    @adv = BLE::AdvertisingData.build do |a|
      a.add(AD_TYPE_FLAGS, AD_FLAGS)
      a.add(AD_TYPE_NAME, "BleRaceRepro")
    end
    db = BLE::GattDatabase.new do |d|
      d.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, SVC_UUID) do |s|
        s.add_characteristic(RX_PROPS, RX_UUID, RX_PROPS, "")
      end
    end
    @rx = db.handle_table[SVC_UUID][RX_UUID][:value_handle]
    @rx_bytes = 0
    super(:peripheral, db.profile_data)
  end

  def packet_callback(event_packet)
    case event_packet[0]&.ord
    when BTSTACK_EVENT_STATE
      advertise(@adv) if event_packet[2]&.ord == BLE::HCI_STATE_WORKING
    when HCI_EVENT_DISCONNECTION_COMPLETE
      advertise(@adv) # re-advertise so flood_rx.rb can reconnect after a crash/reboot
    end
  end

  def heartbeat_callback
    # (1) Drain inbound writes on the main task. Each pop builds an mruby String.
    while (v = pop_write_value(@rx))
      @rx_bytes += v.bytesize
    end
    # (2) Heavy main-task allocator / GC churn to widen the race window against
    #     the BTstack-task BLE_write_data allocations during the flood.
    3000.times do
      a = []
      20.times { a << ("x" * 16) }
    end
    puts "[repro] rx_bytes=#{@rx_bytes}"
  end
end

sleep_ms 1000
puts "[repro] BleRacePeripheral starting (advertising as 'BleRaceRepro')"
BleRacePeripheral.new.start
