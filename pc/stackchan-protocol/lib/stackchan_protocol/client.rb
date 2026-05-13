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
  end
end
