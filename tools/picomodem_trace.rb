# frozen_string_literal: true
#
# Diagnostic probe for the picomodem handshake. Runs the same wire sequence as
# Deploy::Picomodem#await_file_ack but records every byte with a timestamp
# instead of only reporting success or failure, so a "FILE_ACK expected, got
# nil" can be attributed to a specific point in the conversation.
#
# Discriminator: the shell answers Ctrl-B with "\n^B" followed by ACK (0x06)
# before entering PicoModem.session (picoruby-shell/mrblib/shell.rb:421-425).
# Seeing 0x06 means the editor read our STX. Not seeing it means nothing was
# reading serial input at all -- e.g. /home/app.mrb is still running, because
# main_task.rb loads it before it ever constructs the Shell.
#
# Usage: ruby tools/picomodem_trace.rb [PORT] [HANDSHAKE_SECONDS]

require "serialport"

PORT = ARGV[0] || Dir.glob("/dev/cu.usbmodem*").sort.first
HANDSHAKE = (ARGV[1] || 8.0).to_f
abort "no /dev/cu.usbmodem* found" unless PORT

STX          = 0x02
FILE_WRITE   = 0x02
ABORT_CMD    = 0xFF
CURSOR_QUERY = "\e[6n"
CURSOR_REPLY = "\e[1;1R"
DSR_QUERY    = "\e[5n"
DSR_REPLY    = "\e[0n"

T0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
RX = +""

def stamp
  format("%7.3f", Process.clock_gettime(Process::CLOCK_MONOTONIC) - T0)
end

def crc16(data, crc = 0xFFFF)
  data.each_byte do |b|
    crc ^= b << 8
    8.times { crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF }
  end
  crc
end

def make_frame(cmd, payload = "")
  body = [cmd].pack("C") + payload.b
  [STX, body.bytesize].pack("Cn") + body + [crc16(body)].pack("n")
end

def pump(serial, seconds, label, answer_queries:)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  pending = +""
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    next unless serial.wait_readable([remaining, 0.05].min)

    begin
      chunk = serial.read_nonblock(512)
    rescue IO::WaitReadable, EOFError
      next
    end
    next if chunk.nil? || chunk.empty?

    RX << chunk
    puts "#{stamp} [#{label}] rx #{chunk.bytesize}B #{chunk.inspect}"
    next unless answer_queries

    pending << chunk
    while (i = pending.index(CURSOR_QUERY))
      pending.slice!(0, i + CURSOR_QUERY.bytesize)
      serial.write CURSOR_REPLY
      puts "#{stamp} [#{label}] tx cursor reply"
    end
    while (i = pending.index(DSR_QUERY))
      pending.slice!(0, i + DSR_QUERY.bytesize)
      serial.write DSR_REPLY
      puts "#{stamp} [#{label}] tx dsr reply"
    end
    pending.slice!(0, pending.bytesize - 64) if pending.bytesize > 1024
  end
end

puts "#{stamp} opening #{PORT}"
serial = SerialPort.new(PORT, 115_200, 8, 1, SerialPort::NONE)
serial.dtr = 1
puts "#{stamp} opened (DTR=1), handshake window #{HANDSHAKE}s"

begin
  pump(serial, HANDSHAKE, "handshake", answer_queries: true)

  puts "#{stamp} draining"
  pump(serial, 0.5, "drain", answer_queries: false)
  before_stx = RX.bytesize

  puts %(#{stamp} tx STX 0x02 -- expect shell to echo "\\n^B" then ACK 0x06)
  serial.write [STX].pack("C")
  pump(serial, 1.0, "post-stx", answer_queries: false)

  payload = [16].pack("N") + "/home/picomodem_trace_probe.bin"
  puts "#{stamp} tx FILE_WRITE frame (#{make_frame(FILE_WRITE, payload).bytesize}B)"
  serial.write make_frame(FILE_WRITE, payload)
  pump(serial, 5.0, "post-file-write", answer_queries: false)

  puts "#{stamp} tx ABORT to leave any session cleanly"
  serial.write make_frame(ABORT_CMD)
  pump(serial, 1.0, "post-abort", answer_queries: false)

  after = RX.byteslice(before_stx, RX.bytesize - before_stx) || ""
  puts
  puts "=== verdict ==="
  puts "bytes received after STX: #{after.bytesize}"
  puts "shell ACK 0x06 seen:      #{after.include?("\x06")}"
  puts "caret-B echo seen:        #{after.include?("^B")}"
  puts "FILE_ACK frame seen:      #{after.include?("\x02\x00\x02\x82\x01")}"
  puts "raw after STX:            #{after.inspect}"
ensure
  serial.close
end
