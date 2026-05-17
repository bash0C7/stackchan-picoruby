require "corebluetooth_mac"

require_relative "send_builder"
require_relative "frame_codec"

module StackchanBleClient
  class Client
    NUS_RX_CHAR = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
    NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

    def initialize(device_name:, name_prefix: nil, scan_timeout: 10.0, connect_timeout: 5.0, ack_timeout: 3.0, transport: nil)
      @device_name     = device_name
      @name_prefix     = name_prefix
      @scan_timeout    = scan_timeout
      @connect_timeout = connect_timeout
      @ack_timeout     = ack_timeout
      @transport       = transport || build_default_transport
      @peripheral      = nil
      @rx_char         = nil
      @tx_char         = nil
      @subscription    = nil
    end

    def connect
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

    def disconnect
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
      @peripheral = @rx_char = @tx_char = @subscription = nil
    end

    private

    def send_frame(frame)
      @rx_char.write_without_response(frame)
      ack = @subscription.next_value(timeout: @ack_timeout)
      raise TimeoutError, "ACK timeout for frame #{frame.inspect}" if ack.nil?
      case FrameCodec.parse_ack(ack)
      when :ok    then nil
      when :error then raise DeviceError, "device rejected frame #{frame.inspect}"
      end
    rescue CoreBluetoothMac::Error => e
      raise ConnectionError, "#{e.class}: #{e.message}"
    end

    def build_default_transport
      CoreBluetoothMac::Central.new
    end
  end
end
