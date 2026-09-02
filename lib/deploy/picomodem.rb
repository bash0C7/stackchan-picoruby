# frozen_string_literal: true

# PicoModem file uploader for R2P2 (PicoRuby shell), called from the Rakefile.

require "serialport"

module Deploy
  module Picomodem
    # /home/app.mrb autostarts and never returns; retrying cannot help.
    class AutostartBlocked < StandardError; end

    # Raised when the board is not enumerated on USB at all.
    class PortMissing < StandardError; end

    STX        = 0x02
    ACK        = 0x06
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

    # main_task.rb prints these, in this order, on every boot.
    APP_AUTOSTART = "Loading app.mrb"
    SHELL_BANNER  = "Starting shell"

    DEFAULT_BOOT_TIMEOUT = 25.0
    DEFAULT_ATTEMPTS     = 3

    # The USB-Serial/JTAG CDC endpoint re-enumerates ~0.5-2 s after a reset,
    # so the handle that issued the reset must be reopened.
    REENUMERATE_TIMEOUT = 15.0

    # The shell discards input while probing the terminal (read_nonblock in
    # io-console), so wait for quiescence before offering Ctrl-B.
    QUIET_SECONDS = 0.4
    QUIET_CAP     = 8.0

    module_function

    def upload(src:, dst:, port:, baud: 115_200,
               boot_timeout: DEFAULT_BOOT_TIMEOUT,
               attempts: DEFAULT_ATTEMPTS, stdout: $stdout)
      content = File.binread(src)
      stdout.puts "[picomodem] src=#{src} dst=#{dst} port=#{port} size=#{content.bytesize}"
      assert_port_present(port)

      payload = [content.bytesize].pack("N") + dst
      serial  = nil
      attempt = 0
      begin
        loop do
          attempt += 1
          serial&.close
          serial, port = reset_and_reopen(port, baud, stdout)
          await_shell(serial, boot_timeout, stdout)

          reason = offer_file_write(serial, payload, stdout, attempt)
          break if reason.nil?

          if attempt >= attempts
            raise "[picomodem] #{reason} — gave up after #{attempt} attempt(s)"
          end
          stdout.puts "[picomodem] attempt #{attempt} failed: #{reason}; resetting and retrying"
        end

        send_chunks(serial, content, stdout)
      ensure
        serial&.close
      end
      true
    end

    def assert_port_present(port)
      return if File.exist?(port)
      others = Dir.glob("/dev/cu.usbmodem*").sort
      hint = others.empty? ? "no /dev/cu.usbmodem* node exists at all" : "present instead: #{others.inspect}"
      raise PortMissing,
            "[picomodem] #{port} does not exist (#{hint}). The board is not enumerated on USB — " \
            "replug the USB-C cable, or pass ESPPORT=... if the node was renamed."
    end

    # Pulses RTS, waits out re-enumeration, returns [serial, port] (the node
    # can come back under another name).
    def reset_and_reopen(port, baud, stdout)
      pulse = SerialPort.new(port, baud, 8, 1, SerialPort::NONE)
      begin
        pulse.dtr = 0
        pulse.rts = 1
        sleep 0.15
        pulse.rts = 0
      ensure
        pulse.close
      end
      stdout.puts "[picomodem] reset pulsed on #{port}; waiting for USB CDC to re-enumerate"

      deadline = now + REENUMERATE_TIMEOUT
      while now < deadline
        sleep 0.1
        if File.exist?(port)
          begin
            return [SerialPort.new(port, baud, 8, 1, SerialPort::NONE), port]
          rescue Errno::ENOENT, Errno::EBUSY, Errno::EIO
            next
          end
        end
      end

      others = Dir.glob("/dev/cu.usbmodem*").sort
      if others.size == 1
        renamed = others.first
        stdout.puts "[picomodem] WARNING: #{port} never came back; the board re-enumerated as #{renamed}"
        return [SerialPort.new(renamed, baud, 8, 1, SerialPort::NONE), renamed]
      end
      raise PortMissing,
            "[picomodem] #{port} did not come back within #{REENUMERATE_TIMEOUT}s of reset " \
            "(nodes now present: #{others.inspect}). The board dropped off USB — replug it."
    end

    # Reads the boot log until the shell announces itself, answering the
    # editor's terminal queries throughout.
    def await_shell(serial, boot_timeout, stdout)
      stdout.puts "[picomodem] waiting up to #{boot_timeout}s for the shell banner"
      seen      = +""
      pending   = +""
      autostart = false
      deadline  = now + boot_timeout

      while now < deadline
        chunk = read_available(serial, 0.1)
        next unless chunk
        seen << chunk
        pending << chunk
        answer_queries(serial, pending)

        if !autostart && seen.include?(APP_AUTOSTART)
          autostart = true
          stdout.puts "[picomodem] device is loading /home/app.mrb"
        end
        if seen.include?(SHELL_BANNER)
          stdout.puts "[picomodem] shell banner seen#{autostart ? ' (app.mrb returned)' : ''}"
          settle(serial, stdout)
          return
        end
      end

      if autostart
        raise AutostartBlocked,
              "[picomodem] /home/app.mrb started but never returned, so main_task.rb never " \
              "reaches `$shell.start` — the shell that answers Ctrl-B does not exist, and no " \
              "amount of retrying will change that. Run `rake r2p2:wipe_storage` to drop the " \
              "autostart payload, then retry the upload."
      end
      raise "[picomodem] no shell banner and no boot log within #{boot_timeout}s of reset — " \
            "the board is enumerated but silent. Check the USB cable and power."
    end

    # Every sync point is a byte the device emits: "Starting shell" before the
    # editor loop that reads Ctrl-B, ACK 0x06 once PicoModem.session has a reader.
    # Returns nil on success or a string describing where it stopped.
    def offer_file_write(serial, payload, stdout, attempt)
      drain(serial)
      serial.write [STX].pack("C")
      return "shell did not ACK Ctrl-B within 3s" unless wait_for_byte(serial, ACK, timeout: 3.0)

      # PicoModem.session flips STDIN to raw right after writing that ACK.
      sleep 0.05
      serial.write make_frame(FILE_WRITE, payload)
      frame = recv_frame(serial, timeout: 5.0)
      unless frame && frame[0] == FILE_ACK
        return "session entered but FILE_ACK did not arrive (got #{frame.inspect})"
      end
      stdout.puts "[picomodem] FILE_ACK READY (attempt #{attempt})"
      nil
    end

    def send_chunks(serial, content, stdout)
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
      raise "[picomodem] DONE_ACK expected, got #{done.inspect}" unless done && done[0] == DONE_ACK
      stdout.puts "[picomodem] DONE_ACK ok"
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

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def read_exact(io, n, timeout: 5.0)
      buf = +""
      deadline = now + timeout
      while buf.bytesize < n
        remaining = deadline - now
        return nil if remaining <= 0
        return nil unless io.wait_readable(remaining)
        chunk = io.read(n - buf.bytesize)
        return nil if chunk.nil? || chunk.empty?
        buf << chunk
      end
      buf
    end

    def recv_frame(io, timeout: 5.0)
      deadline = now + timeout
      loop do
        remaining = deadline - now
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

    # Answer terminal queries until the device has been quiet for QUIET_SECONDS.
    def settle(serial, stdout)
      pending  = +""
      replies  = 0
      cap      = now + QUIET_CAP
      quiet_at = now + QUIET_SECONDS
      while now < cap && now < quiet_at
        chunk = read_available(serial, 0.05)
        next unless chunk
        pending << chunk
        replies += answer_queries(serial, pending)
        quiet_at = now + QUIET_SECONDS
      end
      stdout.puts "[picomodem] settled after #{format('%.1f', QUIET_SECONDS)}s quiet " \
                  "(terminal queries answered: #{replies})"
    end

    # Answers every \e[6n / \e[5n in buf, consuming what it answers.
    # Returns how many replies were sent.
    def answer_queries(serial, buf)
      replies = 0
      while (i = buf.index(CURSOR_QUERY))
        buf.slice!(0, i + CURSOR_QUERY.bytesize)
        serial.write CURSOR_REPLY
        replies += 1
      end
      while (i = buf.index(DSR_QUERY))
        buf.slice!(0, i + DSR_QUERY.bytesize)
        serial.write DSR_REPLY
        replies += 1
      end
      buf.slice!(0, buf.bytesize - 64) if buf.bytesize > 1024
      replies
    end

    def read_available(io, timeout)
      return nil unless io.wait_readable(timeout)
      io.read_nonblock(512)
    rescue IO::WaitReadable, EOFError, SystemCallError
      # CDC endpoint went away mid-read; let the caller's deadline diagnose it.
      nil
    end

    def wait_for_byte(io, byte, timeout:)
      deadline = now + timeout
      loop do
        remaining = deadline - now
        return false if remaining <= 0
        b = read_exact(io, 1, timeout: remaining)
        return false unless b
        return true if b.getbyte(0) == byte
      end
    end

    def drain(serial)
      while serial.wait_readable(0.1)
        begin
          drained = serial.read_nonblock(256)
          break if drained.nil? || drained.empty?
        rescue IO::WaitReadable, EOFError
          break
        end
      end
    end
  end
end
