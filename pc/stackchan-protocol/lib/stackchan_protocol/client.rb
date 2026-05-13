require "uart"

module StackchanProtocol
  class DeviceError < StandardError; end

  class Client
    attr_reader :port, :baud, :ack_timeout

    def initialize(port:, baud: 115_200, ack_timeout: 0.5, uart_class: UART)
      @port = port
      @baud = baud
      @ack_timeout = ack_timeout
      @uart_class = uart_class
    end

    def open(&block)
      @uart_class.open(@port, @baud, &block)
    end

    def raw_send(serial, byte)
      serial.write(byte)
    end

    def set_face(serial, name)
      byte = FACE_BYTES.fetch(name)
      serial.write(byte)
      ready = serial.wait_readable(@ack_timeout)
      return nil if ready.nil?
      ack = serial.read(1)
      raise DeviceError, "device reported '?' for face=#{name}" if ack == "?"
      nil
    end
  end
end
