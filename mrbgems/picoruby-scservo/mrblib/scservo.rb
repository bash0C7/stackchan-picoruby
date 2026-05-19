require 'uart'

class SCServo
  HEADER          = [0xFF, 0xFF].freeze
  INSTR_PING      = 0x01
  INSTR_READ      = 0x02
  INSTR_WRITE     = 0x03
  REG_TORQUE      = 0x28
  REG_GOAL_POS_L  = 0x2A  # GoalPos(2) + Time(2) + Speed(2) bundled write
  REG_MODE        = 0x21  # 0 = position, 1 = PWM
  REG_PRESENT_POS_L = 0x38
  READ_TIMEOUT_MS = 50
  DRAIN_TIMEOUT_MS = 5
  DRAIN_BUDGET_BYTES = 64

  def initialize(uart, id:)
    @uart = uart
    @id   = id
  end

  def write_pos(pos, time_ms: 0, speed: 0)
    pos_enc   = encode_signed(pos)
    time_enc  = encode_unsigned(time_ms)
    speed_enc = encode_unsigned(speed)
    data = [REG_GOAL_POS_L,
            pos_enc[0],   pos_enc[1],
            time_enc[0],  time_enc[1],
            speed_enc[0], speed_enc[1]]
    send_packet(INSTR_WRITE, data)
    drain_rx
    nil
  end

  def read_pos
    send_packet(INSTR_READ, [REG_PRESENT_POS_L, 0x02])
    raw = @uart.gets   # FakeUART returns nil on :timeout sentinel; on-device UART respects line_ending or timeout
    return nil if raw.nil? || raw.empty?
    bytes = raw.unpack('C*')
    # Expect: 0xFF 0xFF ID LEN ERR pos_L pos_H CKSUM (8 bytes)
    return nil if bytes.length < 8
    return nil unless bytes[0] == 0xFF && bytes[1] == 0xFF
    decode_signed(bytes[5], bytes[6])
  end

  private

  def send_packet(instr, params)
    length = params.length + 2   # instr + params + checksum, minus the LEN byte itself
    body = [@id, length, instr] + params
    sum = body.inject(0) { |acc, b| acc + b }
    cksum = (~sum) & 0xFF
    packet = HEADER + body + [cksum]
    @uart.write(packet)
  end

  def encode_unsigned(v)
    v &= 0xFFFF
    [v & 0xFF, (v >> 8) & 0xFF]
  end

  def encode_signed(v)
    # SCS uses sign-magnitude: bit 15 of the 16-bit value is the sign bit.
    if v < 0
      mag = (-v) & 0x7FFF
      [mag & 0xFF, ((mag >> 8) & 0x7F) | 0x80]
    else
      mag = v & 0x7FFF
      [mag & 0xFF, (mag >> 8) & 0x7F]
    end
  end

  def drain_rx
    # Stub for Task 5; do nothing until we add the real drain.
    nil
  end

  def decode_signed(lo, hi)
    if (hi & 0x80) != 0
      -(((hi & 0x7F) << 8) | lo)
    else
      ((hi & 0x7F) << 8) | lo
    end
  end
end
