require "corebluetooth_mac"

require_relative "send_builder"
require_relative "frame_codec"

module Stackchan::BLE
  class Client
    NUS_RX_CHAR = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
    NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

    attr_reader :last_detail_frame
    attr_accessor :on_unsolicited

    def initialize(device_name:, name_prefix: nil, scan_timeout: 10.0, connect_timeout: 5.0, ack_timeout: 3.0, transport: nil)
      @device_name       = device_name
      @name_prefix       = name_prefix
      @scan_timeout      = scan_timeout
      @connect_timeout   = connect_timeout
      @ack_timeout       = ack_timeout
      @transport         = transport || build_default_transport
      @peripheral        = nil
      @rx_char           = nil
      @tx_char           = nil
      @subscription      = nil
      @last_detail_frame = nil
      @on_unsolicited    = nil
      @inbox             = nil
      @reader_thread     = nil
      @reader_running    = false
    end

    def connect
      @last_detail_frame = nil
      # If name_prefix is set, scan without name filter and match by prefix.
      # Otherwise, use exact name match (legacy behavior).
      if @name_prefix
        devices = @transport.scan(timeout: @scan_timeout)
        devices.select! { |d| d.name&.start_with?(@name_prefix) }
        raise ConnectionError, "no device with name prefix #{@name_prefix.inspect}" if devices.empty?
      else
        devices = @transport.scan(name: @device_name, timeout: @scan_timeout)
        raise ConnectionError, "no device named #{@device_name.inspect}" if devices.empty?
      end
      @peripheral = @transport.connect(devices.first, timeout: @connect_timeout)
      @peripheral.discover_services(timeout: @connect_timeout)
      @peripheral.services.each { |svc| svc.discover_characteristics(timeout: @connect_timeout) if svc.respond_to?(:discover_characteristics) }
      @rx_char = @peripheral.find_characteristic(NUS_RX_CHAR) or raise ConnectionError, "NUS RX not found"
      @tx_char = @peripheral.find_characteristic(NUS_TX_CHAR) or raise ConnectionError, "NUS TX not found"
      @subscription = @tx_char.subscribe
      start_reader
      self
    rescue CoreBluetoothMac::Error => e
      raise ConnectionError, "#{e.class}: #{e.message}"
    end

    def send(&block)
      raise ConnectionError, "not connected" unless @subscription
      builder = SendBuilder.new
      block.call(builder)
      builder.to_frames.each { |frame| send_frame(frame) }
      self
    end

    def raw_send(frame_string)
      raise ConnectionError, "not connected" unless @subscription
      send_frame(frame_string)
      self
    end

    # Raw write to the NUS RX characteristic WITHOUT a device app-level ACK frame.
    # `response:` selects the ATT-layer write type:
    #   - false (default): Write Without Response — flow-controlled by CoreBluetooth
    #     (canSendWriteWithoutResponse). macOS caps the payload at ~182 B regardless
    #     of the negotiated MTU.
    #   - true: Write With Response — each write waits for the ATT Write Response the
    #     device's btstack att_server returns automatically. Allows full-MTU payloads
    #     (≈509 B) and paces the device's BLE task one write at a time. NOTE: this ATT
    #     Write Response is NOT the device's app-level ACK frame (the `<.>`/`<?>`
    #     consumed by #send_frame); audio chunks carry no app ACK.
    def write_without_ack(payload, response: false)
      raise ConnectionError, "not connected" unless @subscription
      if response
        @rx_char.write(payload, response: true)
      else
        @rx_char.write_without_response(payload)
      end
      self
    rescue CoreBluetoothMac::Error => e
      raise ConnectionError, "#{e.class}: #{e.message}"
    end

    # Negotiated maximum write payload (CoreBluetooth maximumWriteValueLength).
    # `response: false` → Write Without Response cap (~182 B on macOS).
    # `response: true`  → Write With Response cap (ATT_MTU-3, ≈509 B) — used by the
    # audio streamer to coalesce chunks and cut the device's per-write cross-thread
    # mruby allocation count.
    def max_write_chunk(response: false)
      raise ConnectionError, "not connected" unless @peripheral
      @peripheral.max_write_length(response: response)
    rescue CoreBluetoothMac::Error => e
      raise ConnectionError, "#{e.class}: #{e.message}"
    end

    # Pop the next non-touch frame the device notified (e.g. a `<rx:...>`
    # throughput summary), or nil on timeout. The reader thread routes
    # non-touch frames into the inbox.
    def read_frame(timeout: 2.0)
      raise ConnectionError, "not connected" unless @inbox
      @inbox.pop(timeout: timeout)
    end

    def disconnect
      stop_reader
      @tx_char&.unsubscribe
      @transport.disconnect(@peripheral) if @peripheral
      @transport.close
      self
    rescue CoreBluetoothMac::Error => e
      # Transport-level "already disconnected" errors map to ConnectionError
      # so the caller (notifier worker, etc.) can treat them uniformly with
      # other transport faults and decide to reconnect.
      raise ConnectionError, "#{e.class}: #{e.message}"
    ensure
      @peripheral = @rx_char = @tx_char = @subscription = @inbox = nil
    end

    private

    def start_reader
      @inbox          = Thread::Queue.new
      @reader_running = true
      @reader_thread  = Thread.new { reader_loop }
    end

    def reader_loop
      while @reader_running
        sub = @subscription
        break unless sub
        begin
          frame = sub.next_value(timeout: 0.2)
        rescue StandardError
          break
        end
        next if frame.nil?
        if FrameCodec.touch_event?(frame)
          cb = @on_unsolicited
          cb.call(frame) if cb
        else
          @inbox.push(frame)
        end
      end
    end

    def stop_reader
      @reader_running = false
      t = @reader_thread
      t.join(1) if t
      @reader_thread = nil
    end

    def send_frame(frame)
      @last_detail_frame = nil
      @rx_char.write_without_response(frame)
      first = @inbox.pop(timeout: @ack_timeout)
      raise TimeoutError, "ACK timeout for frame #{frame.inspect}" if first.nil?
      if first.start_with?(FrameCodec::ACK_OK) || first.start_with?(FrameCodec::ACK_ERROR)
        status = FrameCodec.parse_ack(first)
        if servo_frame?(frame)
          @last_detail_frame = @inbox.pop(timeout: @ack_timeout)
        end
      else
        # Some servo / read frames return only the detail frame (no separate
        # ACK byte) — treat the detail as both confirmation and payload.
        @last_detail_frame = first
        status = :ok
      end
      case status
      when :ok    then nil
      when :error then raise DeviceError, "device rejected frame #{frame.inspect}"
      end
    rescue CoreBluetoothMac::Error => e
      raise ConnectionError, "#{e.class}: #{e.message}"
    end

    def servo_frame?(frame)
      # Device emits a detail frame after:
      # - any frame containing YL / YR / PU axis keys (servo command);
      # - any <read:pos> frame (calibration raw read).
      # Mirror the device-side dispatcher's "emits detail" set
      # (application.rb: servo_present = frame.key?("YL")|..|("PU")).
      !!(frame =~ /(?:YL|YR|PU):/) || frame.start_with?("<read:")
    end

    def build_default_transport
      CoreBluetoothMac::Central.new
    end
  end
end
