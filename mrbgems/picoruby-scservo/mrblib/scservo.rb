require 'uart'

# SCServo (FEETECH SCS series) protocol driver.
# Mirrors github.com/m5stack/StackChan/firmware/main/hal/drivers/FTServo_Arduino
# (SCS.cpp + SCSCL.cpp) byte-for-byte. Comments map each step to its C
# counterpart so future maintainers can re-verify against the upstream
# reference. Do not "simplify" without re-reading SCS.cpp first.

class SCServo
  # SCS protocol header — two leading 0xFF bytes (SCS.cpp:66-67).
  HEADER          = [0xFF, 0xFF].freeze

  # Instruction byte values (INST.h:30-32).
  INSTR_PING      = 0x01
  INSTR_READ      = 0x02
  INSTR_WRITE     = 0x03

  # SCSCL register addresses (SCSCL.h).
  REG_MODE          = 0x21  # SCSCL_MODE (servo mode register on SMS_STS variants)
  REG_TORQUE        = 0x28  # SCSCL_TORQUE_ENABLE = 40
  REG_GOAL_POS_L    = 0x2A  # SCSCL_GOAL_POSITION_L = 42, contiguous: POS_L/H, TIME_L/H, SPEED_L/H
  REG_PRESENT_POS_L = 0x38  # SCSCL_PRESENT_POSITION_L = 56

  # Per-byte read poll budget. SCS.cpp does not specify a numeric timeout —
  # the Arduino HardwareSerial::readBytes default is 1000ms. We use 100ms
  # per response because at 1Mbps a full 8-byte read packet completes in
  # well under 1ms; 100ms covers worst-case servo processing latency.
  READ_TIMEOUT_MS    = 100

  # checkHead() in SCS.cpp:278-298 reads up to 10 bytes before giving up
  # on finding the 0xFF 0xFF header. We use the same budget.
  CHECKHEAD_MAX_SKIP = 10

  def initialize(uart, id:)
    @uart = uart
    @id   = id
  end

  # SCSCL::WritePos (SCSCL.cpp:23-31) — bundled write of POS(2) + TIME(2) + SPEED(2)
  # to REG_GOAL_POS_L. Calls SCS::genWrite which is rFlush + writeBuf + wFlush + Ack.
  def write_pos(pos, time_ms: 0, speed: 0)
    pos_enc   = encode_word(pos)
    time_enc  = encode_word(time_ms)
    speed_enc = encode_word(speed)
    data = [REG_GOAL_POS_L,
            pos_enc[0],   pos_enc[1],
            time_enc[0],  time_enc[1],
            speed_enc[0], speed_enc[1]]
    gen_write(data)
  end

  # SCSCL::ReadPos (SCSCL.cpp:89-100) → SCS::readWord (SCS.cpp:232-242)
  # → SCS::Read (SCS.cpp:172-217). Retries up to 3 times on failure, returning
  # the signed position or nil after all attempts exhausted.
  def read_pos
    3.times do
      result = read_pos_once
      return result unless result.nil?
    end
    nil
  end

  # Diagnostic-only method: send the same READ packet as read_pos, then
  # read up to 32 bytes (echo + response + slack) without checksum / id /
  # length validation. Returns a hex-formatted string of whatever was on RX,
  # or "<empty>" if nothing came back. Used to debug the read_pos timeout
  # hypothesis (echo behaviour / register address / clear_rx_buffer).
  def read_pos_raw_debug
    @uart.clear_rx_buffer
    send_packet(INSTR_READ, [REG_PRESENT_POS_L, 0x02])
    @uart.flush
    # Wait briefly for servo to respond. SCS servos typically reply within
    # 5-10ms; 80ms is a generous budget for diagnostic capture.
    Machine.delay_ms(80)
    raw = ""
    loop do
      chunk = @uart.readpartial(32)
      break if chunk.nil? || chunk.empty?
      raw << chunk
    end
    return "<empty>" if raw.empty?
    hex = ""
    raw.bytes.each { |b| hex << sprintf("%02X ", b) }
    hex.strip
  end

  # SCSCL::EnableTorque (SCSCL.cpp:65-68) → SCS::writeByte (SCS.cpp:152-158).
  def enable_torque(on = true)
    value = on ? 0x01 : 0x00
    gen_write([REG_TORQUE, value])
  end

  # SCSCL::SwitchMode → SCS::writeByte to REG_MODE.
  def set_mode(mode)
    value = case mode
            when :position then 0x00
            when :pwm      then 0x01
            else raise ArgumentError, "unknown mode: #{mode.inspect}"
            end
    gen_write([REG_MODE, value])
  end

  private

  # SCSCL::ReadPos single attempt. Used by read_pos retry wrapper.
  # Returns signed position on success, nil on any failure (timeout, id mismatch,
  # length mismatch, checksum mismatch).
  def read_pos_once
    @uart.clear_rx_buffer
    n = send_packet(INSTR_READ, [REG_PRESENT_POS_L, 0x02])
    @uart.flush
    drain_echo(n)
    return nil unless check_head
    # SCS.cpp:184 — first read = 3 bytes (ID, LEN, ERR).
    body_header = read_bytes(3, READ_TIMEOUT_MS)
    return nil if body_header.nil?
    id_byte  = body_header.bytes[0]
    len_byte = body_header.bytes[1]
    err_byte = body_header.bytes[2]
    return nil if id_byte != @id
    # SCS.cpp:192 — LEN must equal nLen+2 (data + err + checksum byte counts).
    return nil if len_byte != (2 + 2)
    # SCS.cpp:196 — second read = nLen bytes (the actual data).
    data = read_bytes(2, READ_TIMEOUT_MS)
    return nil if data.nil?
    # SCS.cpp:201 — third read = 1 byte (checksum).
    cksum_byte = read_bytes(1, READ_TIMEOUT_MS)
    return nil if cksum_byte.nil?
    # SCS.cpp:205-213 — checksum = ~(ID + LEN + ERR + data...).
    calc_sum = id_byte + len_byte + err_byte
    data.bytes.each { |b| calc_sum += b }
    expected = (~calc_sum) & 0xFF
    return nil if cksum_byte.bytes[0] != expected
    decode_signed(data.bytes[0], data.bytes[1])
  end

  # SCS::genWrite (SCS.cpp:93-99) — rFlush + writeBuf(INST_WRITE) + wFlush + Ack.
  def gen_write(params)
    @uart.clear_rx_buffer
    n = send_packet(INSTR_WRITE, params)
    @uart.flush
    drain_echo(n)
    ack
  end

  # SCS::writeBuf (SCS.cpp:61-89) — assembles and sends:
  #   HEADER(2) + ID + LEN + INSTR + MEMADDR + DATA... + ~CKSUM
  # where LEN = nLen + 2 + 1 = nLen + 3 covering INSTR + MEMADDR + DATA + CKSUM
  # accounting (the LEN byte itself is excluded from LEN per SCS spec).
  #
  # params is [MEMADDR, ...data_bytes] for INSTR_WRITE / INSTR_READ; for
  # PING / RESET / RECOVERY there is no MEMADDR — call sites currently use
  # writes only so this stays as-is.
  def send_packet(instr, params)
    length = params.length + 2
    body = [@id, length, instr] + params
    sum  = body.inject(0) { |acc, b| acc + b }
    cksum = (~sum) & 0xFF
    packet = HEADER + body + [cksum]
    @uart.write(packet.pack('C*'))
    packet.length
  end

  # On ESP32-S3 UART1, TX bytes do NOT loop back on RX in our wiring
  # (verified 2026-05-21 via read_pos_raw_debug capture). drain_echo is a
  # vestigial half-duplex assumption from the Arduino reference; we keep the
  # method signature for compatibility but make it a no-op so check_head sees
  # the real status packet immediately.
  def drain_echo(_n)
  end

  # SCS::checkHead (SCS.cpp:278-298) — slide a 2-byte window byte-by-byte
  # over the RX stream until two consecutive 0xFF bytes are observed.
  # Returns true on success, false after CHECKHEAD_MAX_SKIP bytes.
  def check_head
    last = 0
    skipped = 0
    while skipped <= CHECKHEAD_MAX_SKIP
      byte = read_bytes(1, READ_TIMEOUT_MS)
      return false if byte.nil?
      b = byte.bytes[0]
      return true if last == 0xFF && b == 0xFF
      last = b
      skipped += 1
    end
    false
  end

  # SCS::Ack (SCS.cpp:300-330) — after writeBuf(INST_WRITE), the servo
  # replies with a status packet:
  #   HEADER(2) + ID + LEN(=2) + ERR + ~CKSUM
  # Returns true on success, false on timeout / id mismatch / checksum
  # mismatch. ID 0xFE is broadcast — no ack expected.
  def ack
    return true if @id == 0xFE
    return false unless check_head
    body = read_bytes(4, READ_TIMEOUT_MS)
    return false if body.nil?
    bytes = body.bytes
    return false if bytes[0] != @id
    return false if bytes[1] != 2
    calc = (bytes[0] + bytes[1] + bytes[2]) & 0xFF
    expected = (~calc) & 0xFF
    bytes[3] == expected
  end

  # Polling read of exactly `n` bytes with a `timeout_ms` ms wall clock budget.
  # Replaces Arduino HardwareSerial::readBytes which internally polls with the
  # configured stream timeout. picoruby-uart's read/readpartial are both
  # non-blocking, so we hand-roll the poll loop.
  def read_bytes(n, timeout_ms)
    deadline = (Machine.uptime_us / 1000) + timeout_ms
    buf = ""
    while buf.bytesize < n
      chunk = @uart.readpartial(n - buf.bytesize)
      if chunk && !chunk.empty?
        buf << chunk
      else
        return nil if (Machine.uptime_us / 1000) > deadline
        Machine.delay_ms(1)
      end
    end
    buf
  end

  # SCS::Host2SCS for big-endian word writes (SCS.cpp:33-42 with End=1).
  # Returns [low_byte, high_byte] regardless of internal storage order;
  # used for time / speed which are unsigned 16-bit. End=1 is the SCSCL
  # default (SCSCL::SCSCL ctor sets End=1).
  def encode_unsigned(v)
    v &= 0xFFFF
    [v & 0xFF, (v >> 8) & 0xFF]
  end

  # SCS sign-magnitude 16-bit encoding (used for goal position).
  # The high byte's MSB is the sign bit; the low 15 bits hold magnitude.
  def encode_signed(v)
    if v < 0
      mag = (-v) & 0x7FFF
      [mag & 0xFF, ((mag >> 8) & 0x7F) | 0x80]
    else
      mag = v & 0x7FFF
      [mag & 0xFF, (mag >> 8) & 0x7F]
    end
  end

  # Inverse of encode_signed for ReadPos return.
  def decode_signed(lo, hi)
    if (hi & 0x80) != 0
      -(((hi & 0x7F) << 8) | lo)
    else
      ((hi & 0x7F) << 8) | lo
    end
  end

  # SCSCL wire encoding: SCS::Host2SCS with End=1 (SCS.cpp:33-42 + SCSCL.cpp:12).
  # Returns [hi, lo] for big-endian transmission; unsigned u16 only.
  # Position is 0-4095, time/speed are unsigned milliseconds / units.
  def encode_word(v)
    v &= 0xFFFF
    [(v >> 8) & 0xFF, v & 0xFF]
  end

  # SCSCL wire decoding: SCS::SCS2Host with End=1 (SCS.cpp:46-58).
  # Args are in wire order (first byte received = hi).
  def decode_word(hi, lo)
    ((hi & 0xFF) << 8) | (lo & 0xFF)
  end
end
