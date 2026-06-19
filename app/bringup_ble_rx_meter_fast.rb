# Phase 4 Spike B RE-MEASURE: BLE Mac->device RX throughput meter, FAST-DRAIN variant.
#
# Differs from bringup_ble_rx_meter.rb in ONE way that turns out to be decisive:
# the original drained the RX array inside heartbeat_callback, which the base
# BLE#start loop only runs when pop_heartbeat is true (~1 s C-side heartbeat
# tick). So the original measured a ~1 s-gated drain — an APP design artifact,
# NOT a picoruby-ble fork limitation. The RX array is not capacity-capped
# (mrb_ary_new_capa(4) is an initial alloc; mrb_ary_push grows it), so the
# measured loss came from somewhere below the Ruby array, not array overflow.
#
# This variant overrides #start with a tight loop that drains the RX array
# EVERY iteration at POLL_MS cadence (default 10 ms), de-gated from the 1 s
# heartbeat — exactly what BLE::UART#start already does at ~100 ms. The summary
# notify still fires on the 1 s heartbeat (the Mac runner only needs the final
# tally). No picoruby-ble fork change. This measures the TRUE app-level baseline:
# if it reaches >=8 KB/s with bounded loss, no fork rework is needed.
#
# Deploy: rake r2p2:build_flash_appmrb SRC=app/bringup_ble_rx_meter_fast.rb
# Pair with: pc/stackchan-ble-client/exe/stackchan-ble-throughput

# [1] 5s escape hatch — crash-loop recovery window.
sleep_ms 5000

require 'ble'
require 'machine'

class RxMeterFast < BLE
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

  # Tight drain cadence. 10 ms gives the BTstack FreeRTOS task room to run while
  # draining the RX array ~100x more often than the original 1 s heartbeat gate.
  POLL_MS = 10

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
    puts "[rx-fast] initialize: super(:peripheral) entering"
    super(:peripheral, db.profile_data)
    puts "[rx-fast] initialize: super returned"
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

  # Override the base BLE#start loop: drain RX EVERY iteration (de-gated from
  # the 1 s heartbeat), emit the summary notify only on the heartbeat tick.
  def start
    hci_power_control(BLE::HCI_POWER_ON)
    while true
      packet = pop_packet
      packet_callback(packet) if packet

      # FAST DRAIN: pull the whole RX array every loop iteration.
      data = pop_write_value(@rx_handle)
      while data
        record(data)
        data = pop_write_value(@rx_handle)
      end

      if pop_heartbeat
        on_heartbeat
      end

      sleep_ms POLL_MS
    end
  ensure
    hci_power_control(BLE::HCI_POWER_OFF)
  end

  def packet_callback(event_packet)
    case event_packet[0]&.ord
    when BTSTACK_EVENT_STATE
      return unless event_packet[2]&.ord == BLE::HCI_STATE_WORKING
      puts "[rx-fast] HCI WORKING — advertising"
      advertise(@adv_data)
    when HCI_EVENT_DISCONNECTION_COMPLETE
      puts "[rx-fast] disconnected (pkts=#{@pkts} bytes=#{@bytes} gaps=#{@gaps})"
      @notify_enabled = false
      @notify_queue   = []
      advertise(@adv_data)
    when ATT_EVENT_CAN_SEND_NOW
      flush_one_frame
    end
  end

  # Runs ~1x/sec (C heartbeat tick). CCCD check + summary notify only — the
  # RX drain has already happened many times since the last tick.
  def on_heartbeat
    cccd = pop_write_value(@tx_cccd_handle)
    if cccd
      @notify_enabled = (cccd == "\x01\x00")
      puts "[rx-fast] notify #{@notify_enabled ? 'enabled' : 'disabled'}"
    end

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

puts "[rx-fast] BLE peripheral starting (POLL_MS=#{RxMeterFast::POLL_MS})"
peri = RxMeterFast.new
peri.debug = true
peri.start
