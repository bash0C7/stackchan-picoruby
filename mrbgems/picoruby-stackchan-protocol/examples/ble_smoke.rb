# examples/ble_smoke.rb — Phase 1 picoruby-ble smoke on CoreS3.
# Advertises 'StackChan-PicoRuby' for 60 seconds then exits so the device
# returns to shell and upload remains race-free.
require 'ble'

class StackChanSmoke < BLE
  # AD types per Bluetooth Core spec
  AD_TYPE_FLAGS = 0x01
  AD_TYPE_COMPLETE_LOCAL_NAME = 0x09
  # LE General Discoverable | BR/EDR Not Supported
  AD_FLAGS = 0x06
  BTSTACK_EVENT_STATE = 0x60

  def initialize
    @adv_data = BLE::AdvertisingData.build do |a|
      a.add(AD_TYPE_FLAGS, AD_FLAGS)
      a.add(AD_TYPE_COMPLETE_LOCAL_NAME, "StackChan-PicoRuby")
    end
    db = BLE::GattDatabase.new do |db|
      db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, BLE::GAP_SERVICE_UUID) do |s|
        s.add_characteristic(BLE::READ, BLE::GAP_DEVICE_NAME_UUID, BLE::READ, "StackChan-PicoRuby")
      end
      # Phase 1 diagnostic (2026-05-15): add custom 0xFFE0 service to test if att_db
      # is actually used by BTstack for GATT discovery. If 0xFFE0 appears in Chrome
      # but the 0x1800 (GAP) service does not, BTstack is special-casing GAP via its
      # own internal handlers (att_db user-supplied 0x1800 is silently ignored).
      # If NEITHER appears, our att_db is not being consulted at all by ATT server.
      db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, 0xFFE0) do |s|
        s.add_characteristic(BLE::READ, 0xFFE1, BLE::READ, "PicoRubyTest")
      end
    end
    @db = db   # ivar 保持 (string body lifetime defense)
    bytes = db.profile_data.bytes
    puts "[ble_smoke] profile_data #{bytes.size} bytes:"
    hex = ""
    i = 0
    while i < bytes.size
      h = bytes[i].to_s(16)
      h = "0#{h}" if h.length == 1
      hex << h << " "
      i += 1
    end
    puts hex
    super(:peripheral, db.profile_data)
  end

  def packet_callback(event_packet)
    case event_packet[0]&.ord
    when BTSTACK_EVENT_STATE
      return unless event_packet[2]&.ord == BLE::HCI_STATE_WORKING
      puts "[ble_smoke] HCI WORKING — advertising as 'StackChan-PicoRuby'"
      advertise(@adv_data)
    end
  end

  def heartbeat_callback
    # no-op for smoke; default would call blink_led which needs GPIO_LED_BLE
  end
end

puts "[ble_smoke] init"
peri = StackChanSmoke.new
peri.debug = true
puts "[ble_smoke] start (60s)"
peri.start(60_000)
puts "[ble_smoke] done"
