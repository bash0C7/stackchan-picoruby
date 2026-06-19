# Phase 4 Spike B bring-up: BLE Mac->device RX throughput meter (device side).
#
# Self-contained app.mrb payload. Advertises the same NUS service the rest of
# the project uses, then counts the central's write-without-response payloads as
# they drain out of the per-handle cap-4 RX array via pop_write_value on the
# heartbeat poll (~1 s tick). Each Mac payload's first byte is a 1-byte sequence
# number (mod 256, matching the Mac ThroughputMeter wire format); the device
# tallies packets / bytes / sequence-gap events and notifies a
# `<rx:pkts=,bytes=,gaps=,last=>` summary every tick so the Mac runner can
# compute sustained goodput + loss%.
#
# NO picoruby-ble fork change (spec §6.3): this measures the *baseline* drain
# rate of the existing cap-4 array + ~1 s poll. A low number here is the
# expected signal that points the decision matrix (§6.4) at "Rework", not a bug.
#
# Deploy: rake r2p2:build_flash_appmrb SRC=app/bringup_ble_rx_meter.rb
# Pair with: pc/stackchan-ble-client/exe/stackchan-ble-throughput

# [1] 5s escape hatch — crash-loop recovery window.
sleep_ms 5000

require 'ble'
require 'machine'

class RxMeter < BLE
  AD_TYPE_FLAGS = 0x01
  AD_TYPE_COMPLETE_LOCAL_NAME = 0x09
  AD_FLAGS = 0x06
  BTSTACK_EVENT_STATE = 0x60
  HCI_EVENT_DISCONNECTION_COMPLETE = 0x05
  ATT_EVENT_CAN_SEND_NOW = 0xB7

  NUS_SERVICE_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x01\x00\x40\x6e"
  NUS_RX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x02\x00\x40\x6e"
  NUS_TX_CHAR_UUID = "\x9e\xca\xdc\x24\x0e\xe5\xa9\xe0\x93\xf3\xa3\xb5\x03\x00\x40\x6e"

  NUS_RX_PROPS     = BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC
  NUS_TX_PROPS     = BLE::READ | BLE::NOTIFY | BLE::DYNAMIC
  NUS_TX_VAL_PROPS = BLE::READ | BLE::DYNAMIC
  NUS_CCCD_PROPS   = BLE::READ | BLE::WRITE | BLE::WRITE_WITHOUT_RESPONSE | BLE::DYNAMIC

  def initialize
    @adv_data = build_adv_data
    db = build_gatt_database
    @rx_handle      = nus_handle(db, NUS_RX_CHAR_UUID, :value_handle)
    @tx_handle      = nus_handle(db, NUS_TX_CHAR_UUID, :value_handle)
    @tx_cccd_handle = nus_handle(db, NUS_TX_CHAR_UUID, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION)
    @notify_enabled = false
    @notify_queue   = []
    @pkts     = 0
    @bytes    = 0
    @gaps     = 0
    @last_seq = -1
    @expected = nil
    puts "[rx-meter] initialize: super(:peripheral) entering"
    super(:peripheral, db.profile_data)
    puts "[rx-meter] initialize: super returned"
  end

  def build_adv_data
    BLE::AdvertisingData.build do |a|
      a.add(AD_TYPE_FLAGS, AD_FLAGS)
      a.add(AD_TYPE_COMPLETE_LOCAL_NAME, "StackChan-PicoRuby")
    end
  end

  def build_gatt_database
    BLE::GattDatabase.new do |db|
      db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, BLE::GAP_SERVICE_UUID) do |s|
        s.add_characteristic(BLE::READ, BLE::GAP_DEVICE_NAME_UUID, BLE::READ, "StackChan-PicoRuby")
      end
      db.add_service(BLE::GATT_PRIMARY_SERVICE_UUID, NUS_SERVICE_UUID) do |s|
        s.add_characteristic(NUS_RX_PROPS, NUS_RX_CHAR_UUID, NUS_RX_PROPS, "")
        s.add_characteristic(NUS_TX_PROPS, NUS_TX_CHAR_UUID, NUS_TX_VAL_PROPS, "") do |c|
          c.add_descriptor(NUS_CCCD_PROPS, BLE::CLIENT_CHARACTERISTIC_CONFIGURATION, "\x00\x00")
        end
      end
    end
  end

  def nus_handle(db, char_uuid, key)
    db.handle_table[NUS_SERVICE_UUID][char_uuid][key]
  end

  def packet_callback(event_packet)
    case event_packet[0]&.ord
    when BTSTACK_EVENT_STATE
      return unless event_packet[2]&.ord == BLE::HCI_STATE_WORKING
      puts "[rx-meter] HCI WORKING — advertising"
      advertise(@adv_data)
    when HCI_EVENT_DISCONNECTION_COMPLETE
      puts "[rx-meter] disconnected"
      @notify_enabled = false
      @notify_queue   = []
      advertise(@adv_data)
    when ATT_EVENT_CAN_SEND_NOW
      flush_one_frame
    end
  end

  def heartbeat_callback
    # Drain the cap-4 RX array as fast as this poll allows.
    data = pop_write_value(@rx_handle)
    while data
      record(data)
      data = pop_write_value(@rx_handle)
    end

    cccd = pop_write_value(@tx_cccd_handle)
    if cccd
      @notify_enabled = (cccd == "\x01\x00")
      puts "[rx-meter] notify #{@notify_enabled ? 'enabled' : 'disabled'}"
    end

    # Emit a running summary each tick so the Mac can read goodput live.
    if @notify_enabled
      @notify_queue << summary_frame
      request_can_send_now_event
    end
  end

  # Each central write = one array element. Payload[0] = 1-byte sequence number
  # (mod 256), matching the Mac-side ThroughputMeter wire format; rest is filler.
  def record(data)
    @pkts  += 1
    @bytes += data.bytesize
    b = data.bytes
    if b.length >= 1
      seq = b[0]
      @gaps += 1 if @expected && seq != @expected
      @expected = (seq + 1) & 0xFF
      @last_seq = seq
    end
  end

  def summary_frame
    "<rx:pkts=#{@pkts},bytes=#{@bytes},gaps=#{@gaps},last=#{@last_seq}>\n"
  end

  def flush_one_frame
    return if @notify_queue.empty?
    frame = @notify_queue.shift
    push_read_value(@tx_handle, frame)
    notify(@tx_handle)
    request_can_send_now_event unless @notify_queue.empty?
  end
end

# Yield to the BTstack FreeRTOS task before BLE.new so advertising actually
# emits RF (memory: cold-boot sleep_ms 3000 BTstack-yield rule).
sleep_ms 3000

puts "[rx-meter] BLE peripheral starting"
peri = RxMeter.new
peri.debug = true
peri.start
