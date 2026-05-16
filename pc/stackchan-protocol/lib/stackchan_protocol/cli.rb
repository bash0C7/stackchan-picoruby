require "optparse"
require_relative "client"

module StackchanProtocol
  module CLI
    module_function

    def run(argv, env: ENV.to_h, uart_class: UART, stderr: $stderr, stdout: $stdout)
      port = nil
      face_for_combo = nil
      led_for_combo = nil
      OptionParser.new do |opts|
        opts.on("--port PORT", "Serial port path") { |p| port = p }
        opts.on("--face NAME",  "Face name (combo only)")             { |f| face_for_combo = f }
        opts.on("--led SPEC",   "LED spec '<color> <mode>' (combo)")  { |l| led_for_combo = l }
      end.parse!(argv)

      port ||= env["STACKCHAN_PORT"]
      unless port
        stderr.puts "error: --port required (or set STACKCHAN_PORT)"
        return 2
      end

      command = argv.shift
      unless command
        stderr.puts "error: command required (face / led / combo / raw)"
        return 2
      end

      client = Client.new(port: port, uart_class: uart_class)
      begin
        client.open do |serial|
          case command
          when "face"
            name = argv.shift
            unless name
              stderr.puts "error: face requires <name>"
              return 2
            end
            client.set_face(serial, name.to_sym)
          when "led"
            color = argv.shift
            mode  = argv.shift || "solid"
            unless color
              stderr.puts "error: led requires <color> [<mode>]"
              return 2
            end
            client.set_led(serial, color, mode)
          when "combo"
            unless face_for_combo && led_for_combo
              stderr.puts "error: combo requires --face NAME --led '<color> <mode>'"
              return 2
            end
            color, mode = led_for_combo.split(/\s+/, 2)
            mode ||= "solid"
            client.set_combo(serial,
                             face_name: face_for_combo.to_sym,
                             color_name: color,
                             mode_name: mode)
          when "raw"
            frame = argv.shift
            unless frame
              stderr.puts "error: raw requires a frame string"
              return 2
            end
            client.raw_send(serial, frame.end_with?("\n") ? frame : frame + "\n")
          else
            stderr.puts "error: unknown command '#{command}'"
            return 2
          end
        end
        0
      rescue DeviceError => e
        stderr.puts "device error: #{e.message}"
        1
      rescue KeyError => e
        stderr.puts "unknown name: #{e.message}"
        2
      end
    end
  end
end
