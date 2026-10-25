# frozen_string_literal: true

# PicoModem file uploader for R2P2 (PicoRuby shell), called from the Rakefile.

require "serialport"
require_relative "../esp_port"

# Host-side deployment helpers that talk to the board.
module Deploy
  # Uploads a file to the board's filesystem over the PicoModem serial protocol of the R2P2 shell.
  module Picomodem
    # /home/app.mrb autostarts and never returns; retrying cannot help.
    # Raised when /home/app.mrb starts and never returns, so the shell never appears.
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

    # Resets the board, waits for the shell, offers the file write and sends the file in chunks, retrying the handshake up to attempts times.
    # Returns true. Raises PortMissing, AutostartBlocked or RuntimeError when the board never answers.
    #: (src: String, dst: String, port: String, ?baud: Integer, ?boot_timeout: Float, ?attempts: Integer, ?stdout: IO) -> true
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

    # Returns when the port node exists. Raises PortMissing otherwise.
    #: (String port) -> void
    def assert_port_present(port)
      return if File.exist?(port)
      others = Dir.glob("/dev/cu.usbmodem*").sort
      hint = others.empty? ? "no /dev/cu.usbmodem* node exists at all" : "present instead: #{others.inspect}"
      raise PortMissing,
            "[picomodem] #{port} does not exist (#{hint}). The board is not enumerated on USB — " \
            "run `bundle exec rake r2p2:boards`; a replug is for the CoreS3 serial missing from that list."
    end

    # Pulses RTS, waits out re-enumeration, returns [serial, port] (the node
    # can come back under another name).
    # Pulses RTS, waits for USB re-enumeration and returns the reopened serial and its port, which may have a new name.
    # Raises PortMissing when the board does not come back.
    #: (String port, Integer baud, IO stdout) -> [IO, String]
    def reset_and_reopen(port, baud, stdout)
      serial = EspPort.serial_of(EspPort.ioreg, port)
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

      renamed = serial && EspPort.port_of(EspPort.ioreg, serial)
      if renamed && renamed != port
        stdout.puts "[picomodem] WARNING: #{port} never came back; USB serial #{serial} re-enumerated as #{renamed}"
        return [SerialPort.new(renamed, baud, 8, 1, SerialPort::NONE), renamed]
      end
      raise PortMissing,
            "[picomodem] #{port} (USB serial #{serial || 'unknown'}) did not come back within #{REENUMERATE_TIMEOUT}s of reset. " \
            "Run `bundle exec rake r2p2:boards`; a replug is for the CoreS3 serial missing from that list."
    end

    # Reads the boot log until the shell announces itself, answering the
    # editor's terminal queries throughout.
    # Reads the boot log until the shell banner appears, answering terminal queries, then lets the output settle.
    # Raises AutostartBlocked when app.mrb loaded but the banner never came, RuntimeError when the board is silent.
    #: (IO serial, Float boot_timeout, IO stdout) -> void
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
    # Sends Ctrl-B and the FILE_WRITE frame and waits for the ACKs.
    # Returns nil on success or a string describing where the handshake stopped.
    #: (IO serial, String payload, IO stdout, Integer attempt) -> String?
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

    # Sends content in CHUNK_SIZE frames, checking each CHUNK_ACK, then checks DONE_ACK.
    # Raises RuntimeError on a missing or wrong ACK.
    #: (IO serial, String content, IO stdout) -> void
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

    # Returns the CRC-16 (polynomial 0x1021) of data, continuing from crc.
    #: (String data, ?Integer crc) -> Integer
    def crc16(data, crc = 0xFFFF)
      data.each_byte do |b|
        crc ^= b << 8
        8.times do
          crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF
        end
      end
      crc
    end

    # Returns a PicoModem frame: STX, length, command byte and payload, CRC-16.
    #: (Integer cmd, ?String payload) -> String
    def make_frame(cmd, payload = "")
      body = [cmd].pack("C") + payload.b
      [STX, body.bytesize].pack("Cn") + body + [crc16(body)].pack("n")
    end

    # Returns the monotonic clock in seconds.
    #: () -> Float
    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Reads exactly n bytes, or returns nil when the timeout passes or the stream ends.
    #: (IO io, Integer n, ?timeout: Float) -> String?
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

    # Reads one frame and returns [command byte, payload], or nil on timeout or CRC mismatch.
    #: (IO io, ?timeout: Float) -> [Integer, String]?
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
    # Answers terminal queries until the device has been quiet for QUIET_SECONDS.
    #: (IO serial, IO stdout) -> void
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
    # Answers each cursor-position and status query in buf and removes them from buf. Returns the number of replies sent.
    #: (IO serial, String buf) -> Integer
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

    # Returns up to 512 bytes if readable within timeout, else nil (also when the endpoint goes away).
    #: (IO io, Float timeout) -> String?
    def read_available(io, timeout)
      return nil unless io.wait_readable(timeout)
      io.read_nonblock(512)
    rescue IO::WaitReadable, EOFError, SystemCallError
      # CDC endpoint went away mid-read; let the caller's deadline diagnose it.
      nil
    end

    # Reads until the given byte arrives. Returns false when the timeout passes.
    #: (IO io, Integer byte, timeout: Float) -> bool
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

    # Discards whatever the serial port has pending.
    #: (IO serial) -> void
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
