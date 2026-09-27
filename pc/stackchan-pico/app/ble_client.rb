module NusResolver
  def nus_uuid(suffix_hi, suffix_lo)
    [0x6e, 0x40, suffix_hi, suffix_lo,
     0xb5, 0xa3, 0xf3, 0x93, 0xe0, 0xa9,
     0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e].pack("C*")
  end

  def rx_uuid; nus_uuid(0x00, 0x02); end
  def tx_uuid; nus_uuid(0x00, 0x03); end
  def drb_rx_uuid; nus_uuid(0x00, 0x04); end
  def drb_tx_uuid; nus_uuid(0x00, 0x05); end

  def cccd_uuid
    [0x00, 0x00, 0x29, 0x02, 0x00, 0x00, 0x10, 0x00,
     0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb].pack("C*")
  end

  def find_characteristic(services, uuid128)
    services.each do |service|
      found = service[:characteristics].find { |ch| ch[:uuid128] == uuid128 }
      return found if found
    end
    nil
  end

  def cccd_handle(characteristic)
    return nil unless characteristic
    descriptor = characteristic[:descriptors].find { |d| d[:uuid128] == cccd_uuid }
    descriptor && descriptor[:handle]
  end

  def classify(frame)
    return :touch if Stackchan::BLE::FrameCodec.touch_event?(frame)
    head = frame[0, 1]
    return :ack if head == Stackchan::BLE::FrameCodec::ACK_OK || head == Stackchan::BLE::FrameCodec::ACK_ERROR
    :other
  end

  module_function :nus_uuid, :rx_uuid, :tx_uuid, :drb_rx_uuid, :drb_tx_uuid, :cccd_uuid,
                  :find_characteristic, :cccd_handle, :classify
end

if Object.const_defined?(:BLE)
  class StackchanRadio < BLE
    attr_reader :target, :conn_handle
    attr_accessor :on_notification

    def initialize(name_prefix:)
      @name_prefix    = name_prefix
      @target         = nil
      @on_notification = nil
      super(:central)
    end

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
      @conn_handle = HCI_CON_HANDLE_INVALID
      @services.clear
      scan(timeout_ms: timeout_ms, stop_state: :TC_IDLE)
    end
  end

  class StackchanCentral
    CONNECT_TIMEOUT_MS        = 15_000
    POLLING_UNIT_MS           = 20
    ACK_TIMEOUT_MS            = 3_000
    SUBSCRIBE_SETTLE_MS       = 200
    AUDIO_DONE_TIMEOUT_MIN_MS = 30_000
    AUDIO_DONE_TIMEOUT_MAX_MS = 180_000
    AUDIO_DONE_BASE_MS        = 3_300
    SUBSCRIBE_ENABLE          = "\x01\x00"
    DRB_URI                   = "drbble://stackchan"

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
      @drb_rx_handle      = nil
      @drb_tx_handle      = nil
      @drb_cccd_handle    = nil
      @drb_inbox          = []
      @drb_sent_at        = nil
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
      if @radio.conn_handle == BLE::HCI_CON_HANDLE_INVALID
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

    def remote
      raise Stackchan::BLE::ConnectionError, "not connected" unless @connected
      @drb_inbox.clear
      DRbBle.register(DRB_URI, self, timeout_ms: ACK_TIMEOUT_MS)
      DRb::DRbObject.new_with_uri(DRB_URI)
    end

    def send_chunk(bytes)
      if @drb_sent_at
        wait = POLLING_UNIT_MS - (Machine.board_millis - @drb_sent_at)
        sleep_ms(wait) if wait > 0
      end
      @radio.write_value_of_characteristic_without_response(@radio.conn_handle, @drb_rx_handle, bytes)
      @drb_sent_at = Machine.board_millis
    end

    def poll
      drain
      @drb_inbox.shift
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
      drb_rx = NusResolver.find_characteristic(services, NusResolver.drb_rx_uuid)
      drb_tx = NusResolver.find_characteristic(services, NusResolver.drb_tx_uuid)
      raise Stackchan::BLE::ConnectionError, "dRuby pair not found" unless drb_rx && drb_tx
      @drb_rx_handle   = drb_rx[:value_handle]
      @drb_tx_handle   = drb_tx[:value_handle]
      @drb_cccd_handle = NusResolver.cccd_handle(drb_tx)
    end

    def subscribe_tx
      [@cccd_handle, @drb_cccd_handle].compact.each do |h|
        @radio.write_characteristic_descriptor_using_descriptor_handle(@radio.conn_handle, h, SUBSCRIBE_ENABLE)
      end
      settle(SUBSCRIBE_SETTLE_MS)
    end

    def settle(ms)
      polls_for(ms).times do
        drain
        sleep_ms(POLLING_UNIT_MS)
      end
    end

    def handle_notification(handle, value)
      if handle == @drb_tx_handle
        @drb_inbox << value
        return
      end
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
          if @last_detail_frame && NusResolver.classify(@last_detail_frame) == :ack
            @log_fn.call("[ble_client] anomaly: detail-frame slot got an ACK-like byte #{@last_detail_frame.inspect} for #{frame.inspect}")
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

    def servo_or_read?(frame)
      frame.include?("YL:") || frame.include?("YR:") || frame.include?("PU:") || frame.start_with?("<read:")
    end
  end
end
