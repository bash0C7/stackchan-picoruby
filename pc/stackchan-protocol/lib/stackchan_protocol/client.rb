require "uart"
require_relative "face_table"
require_relative "led_color_table"
require_relative "frame_writer"

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

    def raw_send(serial, frame_string)
      serial.write(frame_string)
      read_ack(serial, "raw send")
    end

    def set_face(serial, name)
      index = FACE_INDICES.fetch(name)
      send_frame(serial, "face=#{name}", F: index)
    end

    def set_led(serial, color_name, mode_name = "solid")
      r, g, b = LED_COLORS.fetch(color_name)
      mode    = LED_MODES.fetch(mode_name)
      if mode == "o"
        send_frame(serial, "led=off", L: "1", M: mode)
      else
        send_frame(serial, "led=#{color_name} #{mode_name}",
                   L: "1", R: r, G: g, B: b, M: mode)
      end
    end

    def set_combo(serial, face_name:, color_name:, mode_name: "solid")
      face = FACE_INDICES.fetch(face_name)
      r, g, b = LED_COLORS.fetch(color_name)
      mode    = LED_MODES.fetch(mode_name)
      send_frame(serial, "combo=#{face_name}+#{color_name}/#{mode_name}",
                 F: face, L: "1", R: r, G: g, B: b, M: mode)
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

    private

    def send_frame(serial, label, **pairs)
      frame = FrameWriter.encode(**pairs)
      serial.write(frame)
      read_ack(serial, label)
    end

    def read_ack(serial, label)
      ready = serial.wait_readable(@ack_timeout)
      return nil if ready.nil?
      ack = serial.read(1)
      raise DeviceError, "device reported '?' for #{label}" if ack == "?"
      nil
    end
  end
end
