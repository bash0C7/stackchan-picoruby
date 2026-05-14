require "uart"
require_relative "face_table"

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

    def drain(serial, timeout: 1.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      buf = +""
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0
        ready = serial.wait_readable(0)
        break if ready.nil?
        chunk = serial.read(64) || break
        buf << chunk
      end
      buf
    end
  end
end
