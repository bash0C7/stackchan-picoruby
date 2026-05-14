require "optparse"
require_relative "client"

module StackchanProtocol
  module CLI
    module_function

    def run(argv, env: ENV.to_h, uart_class: UART, stderr: $stderr, stdout: $stdout)
      port = nil
      OptionParser.new do |opts|
        opts.on("--port PORT", "Serial port path") { |p| port = p }
      end.parse!(argv)

      port ||= env["STACKCHAN_PORT"]
      unless port
        stderr.puts "error: --port required (or set STACKCHAN_PORT)"
        return 2
      end

      command = argv.shift
      unless command
        stderr.puts "error: command required (neutral/smile/joy/raw <byte>)"
        return 2
      end

      client = Client.new(port: port, uart_class: uart_class)
      begin
        client.open do |serial|
          if command == "raw"
            byte = argv.shift
            unless byte
              stderr.puts "error: raw command requires a byte argument"
              return 2
            end
            client.raw_send(serial, byte)
            ready = serial.wait_readable(client.ack_timeout)
            if ready
              ack = serial.read(1)
              raise DeviceError, "device reported '?' for raw send (byte=#{byte.inspect})" if ack == "?"
            end
          else
            client.set_face(serial, command.to_sym)
          end
        end
        0
      rescue DeviceError => e
        stderr.puts "device error: #{e.message}"
        1
      rescue KeyError => e
        stderr.puts "unknown face: #{e.message}"
        2
      end
    end
  end
end
