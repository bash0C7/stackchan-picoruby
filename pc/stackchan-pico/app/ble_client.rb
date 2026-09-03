# picoruby-ble central for the StackChan NUS. NusResolver is pure logic,
# StackchanRadio is the BLE subclass, StackchanCentral is the verb-facing
# wrapper the daemon holds (same interface as FakeBleClient).
#
# Darwin-port rules this file depends on:
# - StackchanRadio must not define `connect`: BLE#connect(report) is called by
#   name from advertising_report_callback. Connecting from inside that callback
#   lets one `scan` call drive connect + full GATT discovery.
# - After the initial scan, never call scan/start/connect again: BLE#start
#   re-powers the controller and the port flushes its FIFO, dropping in-flight
#   packets. Drain with pop_and_dispatch only.
# - The port synthesizes GATT_EVENT_NOTIFICATION (0xA7); ble_central.rb leaves
#   it undecoded, so packet_callback here handles it after super.

module NusResolver
  # bare `module_function` is a no-op on PicoRuby; use the explicit form.

  # 16-byte UUID; suffix 0x0001 = service, 0x0002 = RX (write), 0x0003 = TX (notify)
  def nus_uuid(suffix_hi, suffix_lo)
    [0x6e, 0x40, suffix_hi, suffix_lo,
     0xb5, 0xa3, 0xf3, 0x93, 0xe0, 0xa9,
     0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e].pack("C*")
  end

  def rx_uuid; nus_uuid(0x00, 0x02); end
  def tx_uuid; nus_uuid(0x00, 0x03); end

  def cccd_uuid
    [0x00, 0x00, 0x29, 0x02, 0x00, 0x00, 0x10, 0x00,
     0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb].pack("C*")
  end

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

  # :touch (<touch:N>), :ack ("."/"?"), :detail (<..._actual:..>/<yaw_raw:..>), :other
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

# `defined?(BLE)` guards: this file also loads on a VM without the ble gem.
if Object.const_defined?(:BLE)
  class StackchanRadio < BLE
    attr_reader :target

    def initialize(name_prefix:)
      @name_prefix    = name_prefix
      @target         = nil
      @on_notification = nil
      super(:central)
    end

    attr_accessor :on_notification

    def conn_handle
      @conn_handle
    end

    # `_event_popped` first: on the darwin port it is the only place a packet
    # moves from the Swift FIFO into @event_queue.
    def pop_and_dispatch
      _event_popped
      event = @event_queue.pop(timeout_ms: 0)
      return nil unless event
      packet_callback(event) if event.is_a?(String)
      event
    end

    def advertising_report_callback(report)
      return if @target
      return unless report.name_include?(@name_prefix)
      @target = report
      connect(report)
    end

    def packet_callback(event_packet)
      super
      return unless event_packet.getbyte(0) == GATT_EVENT_NOTIFICATION
      handle = BLE::Utils.little_endian_to_int16(event_packet.byteslice(4, 1))
      len    = BLE::Utils.little_endian_to_int16(event_packet.byteslice(6, 1))
      cb = @on_notification
      cb.call(handle, event_packet.byteslice(8, len)) if cb
    end

    def connect_and_discover(timeout_ms)
      @target = nil
      scan(timeout_ms: timeout_ms, stop_state: :TC_IDLE)
    end
  end

  #
  # Every wait is a poll loop in POLLING_UNIT_MS steps; budgets are in ms.
  class StackchanCentral
    CONNECT_TIMEOUT_MS        = 15_000   # scan-wait + connect + full GATT discovery
    POLLING_UNIT_MS           = 20
    ACK_TIMEOUT_MS            = 3_000
    SUBSCRIBE_SETTLE_MS       = 200      # CoreBluetooth setNotifyValue needs a moment before the first write
    AUDIO_DONE_TIMEOUT_MIN_MS = 30_000   # floor (previous fixed value; short-clip behavior unchanged)
    AUDIO_DONE_TIMEOUT_MAX_MS = 180_000  # hard cap -- never an unbounded wait
    AUDIO_DONE_BASE_MS        = 3_300    # measured intercept, see audio_done_timeout_ms
    SUBSCRIBE_ENABLE          = "\x01\x00"

    attr_accessor :on_unsolicited
    attr_reader   :last_detail_frame

    def initialize(name_prefix: "StackChan", radio: nil, log_fn: nil)
      @name_prefix        = name_prefix
      @radio              = radio || StackchanRadio.new(name_prefix: name_prefix)
      @radio.on_notification = method(:handle_notification)
      @log_fn             = log_fn   || ->(line) { $stderr.write(line + "\n"); $stderr.flush }
      @rx_handle          = nil
      @tx_handle          = nil
      @cccd_handle        = nil
      @inbox              = []
      @connected          = false
      @on_unsolicited     = nil
      @last_detail_frame  = nil
    end

    def connected?
      @connected
    end

    def connect
      @radio.connect_and_discover(CONNECT_TIMEOUT_MS)
      unless @radio.target
        raise Stackchan::BLE::ConnectionError, "no #{@name_prefix} advertiser found"
      end
      # @state is reset to :TC_OFF after scan whether or not discovery
      # succeeded; @conn_handle is the success signal.
      unless @radio.conn_handle != BLE::HCI_CON_HANDLE_INVALID
        raise Stackchan::BLE::ConnectionError, "GATT connect did not complete"
      end
      resolve_handles
      subscribe_tx
      @connected = true
      self
    end

    def disconnect
      @connected = false
      self
    end

    # The darwin port exposes no MTU query; macOS write-without-response cap.
    def max_write_chunk
      180
    end

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

    # Safety net for a lost <A:done>; scales with clip size (~0.95 ms/byte +
    # 3.3 s base measured, 1.2 ms/byte used).
    def audio_done_timeout_ms(n)
      ms = AUDIO_DONE_BASE_MS + (n * 6 / 5)
      return AUDIO_DONE_TIMEOUT_MIN_MS if ms < AUDIO_DONE_TIMEOUT_MIN_MS
      return AUDIO_DONE_TIMEOUT_MAX_MS if ms > AUDIO_DONE_TIMEOUT_MAX_MS
      ms
    end

    def await_audio_done(n)
      raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
      @inbox.clear
      polls = polls_for(audio_done_timeout_ms(n))
      i = 0
      while true
        drain
        idx = @inbox.index { |f| f.start_with?("<A:done>") }
        if idx
          @inbox.delete_at(idx)
          return self
        end
        raise Stackchan::BLE::TimeoutError, "<A:done> timeout" if i >= polls
        sleep_ms(POLLING_UNIT_MS)
        i += 1
      end
    end

    def drain
      while @radio.pop_and_dispatch
      end
    end

    private

    def polls_for(ms)
      (ms + POLLING_UNIT_MS - 1) / POLLING_UNIT_MS
    end

    def resolve_handles
      services = @radio.services
      rx = NusResolver.find_characteristic(services, NusResolver.rx_uuid)
      tx = NusResolver.find_characteristic(services, NusResolver.tx_uuid)
      raise Stackchan::BLE::ConnectionError, "NUS RX not found" unless rx
      raise Stackchan::BLE::ConnectionError, "NUS TX not found" unless tx
      @rx_handle   = rx[:value_handle]
      @tx_handle   = tx[:value_handle]
      @cccd_handle = NusResolver.cccd_handle(tx)
    end

    # Subscribe TX, then drain SUBSCRIBE_SETTLE_MS: there is no central-side
    # "subscribe complete" event to wait on.
    def subscribe_tx
      return unless @cccd_handle
      @radio.write_characteristic_descriptor_using_descriptor_handle(
        @radio.conn_handle, @cccd_handle, SUBSCRIBE_ENABLE)
      settle(SUBSCRIBE_SETTLE_MS)
    end

    def settle(ms)
      polls_for(ms).times do
        drain
        sleep_ms(POLLING_UNIT_MS)
      end
    end

    def handle_notification(handle, value)
      return unless handle == @tx_handle
      case NusResolver.classify(value)
      when :touch
        cb = @on_unsolicited
        cb.call(value) if cb
      else
        @inbox << value
      end
    end

    def write_rx(payload)
      @radio.write_value_of_characteristic_without_response(@radio.conn_handle, @rx_handle, payload)
    end

    def write_and_await_ack(frame)
      @last_detail_frame = nil
      @inbox.clear
      t0 = Machine.board_millis
      write_rx(frame)
      first = await_inbox
      unless first
        @log_fn.call("[t] #{frame.chomp} ack=timeout")
        raise Stackchan::BLE::TimeoutError, "ACK timeout for #{frame.inspect}"
      end
      t_ack = Machine.board_millis
      status = NusResolver.classify(first)
      if status == :ack
        t_detail = nil
        if servo_or_read?(frame)
          @last_detail_frame = await_inbox
          t_detail = @last_detail_frame ? Machine.board_millis : :timeout
          # Log raw bytes if the detail await returns a bare ACK byte (seen once, unexplained).
          if @last_detail_frame && NusResolver.classify(@last_detail_frame) == :ack
            $stderr.write("[ble_client] anomaly: detail-frame slot got an ACK-like byte #{@last_detail_frame.inspect} for #{frame.inspect}\n")
            $stderr.flush
          end
        end
        log_timing(frame, t0, t_ack, t_detail)
        return if first[0, 1] == Stackchan::BLE::FrameCodec::ACK_OK
        raise Stackchan::BLE::DeviceError, "device rejected #{frame.inspect}"
      else
        @last_detail_frame = first
        log_timing(frame, t0, t_ack, nil)
      end
    end

    # One line per command in daemon.log: write→ACK (and →detail) latency in ms.
    def log_timing(frame, t0, t_ack, t_detail)
      line = "[t] #{frame.chomp} ack=#{t_ack - t0}ms"
      if t_detail == :timeout
        line += " detail=timeout"
      elsif t_detail
        line += " detail=#{t_detail - t0}ms"
      end
      @log_fn.call(line)
    end

    def await_inbox
      polls = polls_for(ACK_TIMEOUT_MS)
      i = 0
      while true
        drain
        return @inbox.shift unless @inbox.empty?
        return nil if i >= polls
        sleep_ms(POLLING_UNIT_MS)
        i += 1
      end
    end

    # No alternation regex on PicoRuby — String includes.
    def servo_or_read?(frame)
      frame.include?("YL:") || frame.include?("YR:") || frame.include?("PU:") || frame.start_with?("<read:")
    end
  end
end
