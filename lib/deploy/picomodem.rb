# frozen_string_literal: true

# PicoModem file uploader for R2P2 (PicoRuby shell). Ported from
# pc/stackchan-protocol/exe/picomodem-upload as part of Phase 3 (2026-05-17);
# the gem is being retired so the upload logic now lives at the project root
# as a Rakefile-callable Ruby module.
#
# See the original exe header (still in git history as of Phase 2) for the
# rationale on the handshake-responder phase.

require "serialport"

module Deploy
  module Picomodem
    STX        = 0x02
    FILE_WRITE = 0x02
    CHUNK      = 0x04
    FILE_ACK   = 0x82
    CHUNK_ACK  = 0x84
    DONE_ACK   = 0x8F
    CHUNK_SIZE = 480

    CURSOR_QUERY = "\e[6n"
    CURSOR_REPLY = "\e[1;1R"
    DSR_QUERY    = "\e[5n"
    DSR_REPLY    = "\e[0n"

    DEFAULT_HANDSHAKE_SECONDS = 8.0

    module_function

    def upload(src:, dst:, port:, baud: 115_200,
               handshake_seconds: DEFAULT_HANDSHAKE_SECONDS, stdout: $stdout)
      content = File.binread(src)
      stdout.puts "[picomodem] src=#{src} dst=#{dst} port=#{port} size=#{content.bytesize}"

      serial = SerialPort.new(port, baud, 8, 1, SerialPort::NONE)
      serial.dtr = 1
      stdout.puts "[picomodem] opened #{port} @ #{baud} (DTR=1)"
      begin
        run_handshake_responder(serial, handshake_seconds, stdout)
        drain(serial)

        # Single STX byte triggers PicoModem.session on the shell side.
        serial.write [STX].pack("C")
        sleep 0.05

        payload = [content.bytesize].pack("N") + dst
        serial.write make_frame(FILE_WRITE, payload)

        frame = recv_frame(serial, timeout: 5.0)
        unless frame && frame[0] == FILE_ACK
          raise "[picomodem] FILE_ACK expected, got #{frame.inspect}"
        end
        stdout.puts "[picomodem] FILE_ACK READY"

        offset = 0
        while offset < content.bytesize
          chunk = content.byteslice(offset, CHUNK_SIZE)
          serial.write make_frame(CHUNK, chunk)
          ack = recv_frame(serial, timeout: 5.0)
          unless ack && ack[0] == CHUNK_ACK
            raise "[picomodem] CHUNK_ACK expected at offset=#{offset}, got #{ack.inspect}"
          end
          offset += chunk.bytesize
          stdout.print "."
          stdout.flush
        end
        stdout.puts

        done = recv_frame(serial, timeout: 5.0)
        unless done && done[0] == DONE_ACK
          raise "[picomodem] DONE_ACK expected, got #{done.inspect}"
        end
        stdout.puts "[picomodem] DONE_ACK ok"
      ensure
        serial.close
      end
      true
    end

    def crc16(data, crc = 0xFFFF)
      data.each_byte do |b|
        crc ^= b << 8
        8.times do
          crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF
        end
      end
      crc
    end

    def make_frame(cmd, payload = "")
      body = [cmd].pack("C") + payload.b
      [STX, body.bytesize].pack("Cn") + body + [crc16(body)].pack("n")
    end

    def read_exact(io, n, timeout: 5.0)
      buf = +""
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      while buf.bytesize < n
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if remaining <= 0
        return nil unless io.wait_readable(remaining)
        chunk = io.read(n - buf.bytesize)
        return nil if chunk.nil? || chunk.empty?
        buf << chunk
      end
      buf
    end

    def recv_frame(io, timeout: 5.0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if remaining <= 0
        b = read_exact(io, 1, timeout: remaining)
        return nil unless b
        break if b.bytes[0] == STX
      end
      len_bytes = read_exact(io, 2, timeout: timeout)
      return nil unless len_bytes
      length = len_bytes.unpack1("n")
      rest = read_exact(io, length + 2, timeout: timeout)
      return nil unless rest
      body     = rest.byteslice(0, length)
      expected = rest.byteslice(length, 2).unpack1("n")
      return nil unless crc16(body) == expected
      [body.getbyte(0), body.byteslice(1, length - 1) || ""]
    end

    def run_handshake_responder(serial, duration, stdout)
      stop = false
      cursor_replies = 0
      dsr_replies    = 0
      buf = +""
      thr = Thread.new do
        while !stop
          if serial.wait_readable(0.05)
            begin
              chunk = serial.read_nonblock(256)
              buf << chunk if chunk && !chunk.empty?
              while (i = buf.index(CURSOR_QUERY))
                buf.slice!(0, i + CURSOR_QUERY.bytesize)
                serial.write CURSOR_REPLY
                cursor_replies += 1
              end
              while (i = buf.index(DSR_QUERY))
                buf.slice!(0, i + DSR_QUERY.bytesize)
                serial.write DSR_REPLY
                dsr_replies += 1
              end
              buf.slice!(0, buf.bytesize - 64) if buf.bytesize > 1024
            rescue IO::WaitReadable, EOFError
              # transient — wait_readable returned but read_nonblock raced or
              # device went away briefly; the outer loop will retry.
            end
          end
        end
      end
      stdout.puts "[picomodem] handshake phase: #{duration}s (answers \\e[6n / \\e[5n so editor unblocks)"
      sleep duration
      stop = true
      thr.join
      stdout.puts "[picomodem] handshake done: cursor_replies=#{cursor_replies} dsr_replies=#{dsr_replies}"
    end

    def drain(serial)
      while serial.wait_readable(0.1)
        begin
          drained = serial.read_nonblock(256)
          break if drained.nil? || drained.empty?
        rescue IO::WaitReadable, EOFError
          # transient — drain ended; either no more data is buffered or the
          # device hiccuped. Either way we are done flushing.
          break
        end
      end
    end
  end
end
