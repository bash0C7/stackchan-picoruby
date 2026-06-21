# Real picoruby-ble central client for the StackChan NUS. Replaces FakeBleClient
# in deployment. Two parts:
#
#   NusResolver  — PURE logic (UUID -> handle resolution, frame classification).
#                  Host-testable without a radio (see test below).
#   StackchanCentral — the BLE subclass that drives scan/connect/discover/write/
#                  notify over picoruby-ble's event-driven central API.
#
# LIVE STATUS: NusResolver is verified on host. StackchanCentral's radio
# interaction is NOT verified here — it needs a physical StackChan (sub-project
# #5). The picoruby-ble central model differs fundamentally from the CRuby
# CoreBluetoothMac client and must be validated against hardware:
#   - `BLE#start(timeout, stop_state)` is a 100ms polling pump that powers the
#     HCI radio OFF in its `ensure` when it returns. A persistent daemon link
#     therefore cannot use repeated start/stop cycles (each would drop the
#     radio); it must run ONE continuous `start` (infinite, :no_stop) as an
#     event-pump Task, with discovery completing inside that single run and
#     writes issued from a separate Task while the pump keeps the radio up.
#   - Inbound ACK/detail/touch frames arrive as GATT_EVENT_NOTIFICATION (0xA7)
#     packets in packet_callback; they must be routed into an inbox the verb
#     Task drains (mirrors the CRuby reader_loop).
# The exact ordering/timing of connect -> discovery-complete -> CCCD subscribe
# -> first write is the part that needs live iteration.

module NusResolver
  # NOTE: bare `module_function` is a no-op on PicoRuby; the explicit
  # `module_function :sym, ...` form at the end of the module is required.

  # 16-byte big-endian UUID for a Nordic UART Service member.
  #   suffix 0x0001 = service, 0x0002 = RX (write), 0x0003 = TX (notify)
  def nus_uuid(suffix_hi, suffix_lo)
    [0x6e, 0x40, suffix_hi, suffix_lo,
     0xb5, 0xa3, 0xf3, 0x93, 0xe0, 0xa9,
     0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e].pack("C*")
  end

  def rx_uuid; nus_uuid(0x00, 0x02); end
  def tx_uuid; nus_uuid(0x00, 0x03); end

  # CCCD (Client Characteristic Configuration Descriptor) UUID 0x2902, as the
  # 16-byte form the central stores after reverse_128.
  def cccd_uuid
    [0x00, 0x00, 0x29, 0x02, 0x00, 0x00, 0x10, 0x00,
     0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb].pack("C*")
  end

  # Find a characteristic Hash (the shape ble_central.rb builds) by uuid128
  # across all discovered services. Returns nil if absent.
  def find_characteristic(services, uuid128)
    si = 0
    while si < services.size
      chs = services[si][:characteristics]
      ci = 0
      while ci < chs.size
        return chs[ci] if chs[ci][:uuid128] == uuid128
        ci += 1
      end
      si += 1
    end
    nil
  end

  # The CCCD descriptor handle of a characteristic, or nil.
  def cccd_handle(characteristic)
    return nil unless characteristic
    ds = characteristic[:descriptors]
    i = 0
    while i < ds.size
      return ds[i][:handle] if ds[i][:uuid128] == cccd_uuid
      i += 1
    end
    nil
  end

  # Classify an inbound notified frame the way the daemon's reader needs:
  #   :touch  — unsolicited <touch:N> (route to touch handler)
  #   :ack    — bare "." / "?" ACK byte
  #   :detail — a servo/read detail frame (<..._actual:..> / <yaw_raw:..>)
  #   :other  — anything else (e.g. <rx:...> throughput summary)
  def classify(frame)
    return :touch if Stackchan::BLE::FrameCodec.touch_event?(frame)
    head = frame[0, 1]
    return :ack if head == Stackchan::BLE::FrameCodec::ACK_OK || head == Stackchan::BLE::FrameCodec::ACK_ERROR
    return :detail if frame.include?("_actual:") || frame.include?("_raw:")
    :other
  end

  module_function :nus_uuid, :rx_uuid, :tx_uuid, :cccd_uuid,
                  :find_characteristic, :cccd_handle, :classify
end

# Drop-in replacement for FakeBleClient using picoruby-ble's central API.
# Implements the same interface the daemon depends on: connect / connected? /
# send{|builder| } / raw_send / write_without_ack / last_detail_frame /
# on_unsolicited= / disconnect.
#
# LIVE-PENDING (#5): every method that touches the radio (scan, gap_connect,
# the `start` event pump, write_value_*) is unverified — it needs a physical
# StackChan. The notification ROUTING (route_notification) and the cooperative
# inbox/ACK-wait are pure and host-checkable. `defined?(BLE)` guards the
# subclassing so this file also loads on a VM without the ble gem (for testing
# NusResolver / the routing helpers in isolation).
if Object.const_defined?(:BLE)
  class StackchanCentral < BLE
    ACK_TIMEOUT_TICKS = 30        # x POLLING_UNIT_MS(100ms) = ~3s
    SUBSCRIBE_ENABLE  = "\x01\x00" # CCCD: notifications on

    attr_accessor :on_unsolicited
    attr_reader   :last_detail_frame

    def initialize(name_prefix: "StackChan")
      @name_prefix       = name_prefix
      @target            = nil
      @rx_handle         = nil
      @tx_handle         = nil
      @cccd_handle       = nil
      @inbox             = []      # ACK/detail/other frames (no Queue on PicoRuby)
      @connected         = false
      @on_unsolicited    = nil
      @last_detail_frame = nil
      @pump_task         = nil
      super(:central)
    end

    def connected?
      @connected
    end

    # Override: collect the first advertiser whose name matches the prefix.
    def advertising_report_callback(report)
      return if @target
      name = (report.name rescue nil)
      @target = report if name && name.start_with?(@name_prefix)
    end

    # Route an inbound notified frame: touch -> on_unsolicited callback;
    # everything else (ACK / detail / other) -> inbox for the verb Task. This
    # is pure and host-testable (see route_notification_test).
    def route_notification(frame)
      case NusResolver.classify(frame)
      when :touch
        cb = @on_unsolicited
        cb.call(frame) if cb
      else
        @inbox << frame
      end
    end

    # LIVE-PENDING (#5): scan -> connect -> discover -> resolve handles ->
    # subscribe -> start the event-pump Task. The HCI-power lifecycle of
    # BLE#start (powers off on return) means the pump must be ONE infinite
    # `start`; connect's discovery must complete inside it. Exact sequencing
    # needs hardware iteration.
    def connect
      raise NotImplementedError,
            "StackchanCentral#connect: live BLE wiring pending sub-project #5 " \
            "(scan/connect/discover/subscribe + event-pump Task vs HCI power lifecycle)"
    end

    def disconnect
      @pump_task&.terminate
      @connected = false
      self
    end

    # Build frames via the shared SendBuilder and write each to RX, waiting for
    # the device ACK (+ detail frame for servo/read). Mirrors the CRuby
    # Client#send. The write primitive and the pump that fills @inbox are
    # LIVE-PENDING; the ACK-wait control flow is the real logic.
    def send
      raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
      b = Stackchan::BLE::SendBuilder.new
      yield b
      b.to_frames.each { |frame| write_and_await_ack(frame) }
      self
    end

    def raw_send(frame)
      raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
      write_and_await_ack(frame)
      self
    end

    def write_without_ack(payload)
      raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
      write_rx(payload)
      self
    end

    private

    # LIVE-PENDING (#5): the actual characteristic write.
    def write_rx(payload)
      write_value_of_characteristic_without_response(@conn_handle, @rx_handle, payload)
    end

    def write_and_await_ack(frame)
      @last_detail_frame = nil
      @inbox.clear
      write_rx(frame)
      first = await_inbox
      raise Stackchan::BLE::TimeoutError, "ACK timeout for #{frame.inspect}" unless first
      status = NusResolver.classify(first)
      if status == :ack
        @last_detail_frame = await_inbox if servo_or_read?(frame)
        return if first[0, 1] == Stackchan::BLE::FrameCodec::ACK_OK
        raise Stackchan::BLE::DeviceError, "device rejected #{frame.inspect}"
      else
        # detail-only response (no separate ACK byte)
        @last_detail_frame = first
      end
    end

    # Cooperative wait: yield to the event-pump Task until a frame lands in the
    # inbox or the tick budget runs out (no blocking Queue#pop on PicoRuby).
    def await_inbox
      ticks = 0
      while @inbox.empty? && ticks < ACK_TIMEOUT_TICKS
        Task.pass
        sleep(BLE::POLLING_UNIT_MS / 1000.0) rescue sleep(0.1)
        ticks += 1
      end
      @inbox.shift
    end

    # No alternation regex on PicoRuby — String includes.
    def servo_or_read?(frame)
      frame.include?("YL:") || frame.include?("YR:") || frame.include?("PU:") || frame.start_with?("<read:")
    end
  end
end

