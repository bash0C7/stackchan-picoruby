# frozen_string_literal: true

# R2P2 shell recovery helper. Designed to interrupt an autostarting /home/app.mrb
# via Ctrl-C and then blind-send `rm /home/app.mrb` so the next boot drops into a
# clean shell prompt.
#
# CURRENT STATUS (2026-05-17 R2P2-ESP32 build): non-functional. The device's
# main_task exits after SIGINT and never re-prints a shell prompt over the
# uart-gem-backed serial path, so the blind-send rm never reaches a shell.
# `rake r2p2:wipe_storage` (esptool erase_region) is the working alternative.
#
# Kept around as future-proof scaffolding: if a future R2P2 build restores
# post-SIGINT shell echo, or if DTR signaling is added to the uart gem path,
# this helper becomes useful again with minimal modification.

require "uart"

module Deploy
  module ShellRecovery
    CTRL_C = "\x03"

    module_function

    def rm_app(port:, baud: 115_200, stdout: $stdout)
      UART.open(port, baud) do |serial|
        stdout.puts "[recovery] opened #{port}"
        collected = collect_until(serial, timeout: 10.0, match: "SIGINT",
                                  ctrl_c_interval: 0.4, stdout: stdout)
        unless collected[:matched]
          raise "[recovery] SIGINT not observed in 10s. Bytes seen: #{collected[:bytes].inspect}"
        end
        stdout.puts "[recovery] SIGINT confirmed. Draining post-exit output (2s)..."
        sleep 2
        drain(serial, stdout: stdout)
        stdout.puts "[recovery] sending blind: rm /home/app.mrb"
        serial.write "rm /home/app.mrb\r"
        sleep 1.5
        after_rm = drain(serial, stdout: stdout, label: "after-rm")
        stdout.puts "[recovery] done. Verify with a fresh reset + boot capture: no '[application] boot' = app.mrb removed."
        { matched: true, post_rm_bytes: after_rm }
      end
    end

    def collect_until(serial, timeout:, match:, ctrl_c_interval:, stdout:)
      deadline    = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      next_ctrl_c = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      buf         = +""
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if now >= next_ctrl_c
          serial.write CTRL_C
          next_ctrl_c = now + ctrl_c_interval
        end
        if serial.wait_readable(0.1)
          begin
            chunk = serial.read_nonblock(512)
            if chunk && !chunk.empty?
              buf << chunk
              stdout.puts "[recovery]   +#{chunk.bytesize}B: #{chunk.inspect}"
              return { matched: true, bytes: buf } if buf.include?(match)
            end
          rescue IO::WaitReadable, EOFError
            # transient
          end
        end
      end
      { matched: false, bytes: buf }
    end

    def drain(serial, stdout:, label: "drain")
      buf = +""
      loop_count = 0
      while serial.wait_readable(0.2) && loop_count < 30
        begin
          chunk = serial.read_nonblock(512)
          break if chunk.nil? || chunk.empty?
          buf << chunk
          stdout.puts "[recovery]   #{label} +#{chunk.bytesize}B: #{chunk.inspect}"
        rescue IO::WaitReadable, EOFError
          break
        end
        loop_count += 1
      end
      buf
    end
  end
end
