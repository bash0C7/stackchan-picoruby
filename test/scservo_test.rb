$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class SCServoTest < Test::Unit::TestCase
  def test_initializes_with_uart_and_id
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    assert_kind_of SCServo, servo
  end

  def test_write_pos_emits_correct_packet
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 1000, speed: 0)
    # ID=1, LEN=9, INSTR=0x03, REG=0x2A,
    # pos=500=0x01F4 -> [0xF4,0x01], time=1000=0x03E8 -> [0xE8,0x03], speed=0 -> [0x00,0x00]
    # checksum = ~(1+9+3+0x2A+0xF4+1+0xE8+3+0+0) & 0xFF
    #         = ~(1+9+3+42+244+1+232+3+0+0) & 0xFF = ~0x17 & 0xFF = 0xE8
    expected = [0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A,
                0xF4, 0x01, 0xE8, 0x03, 0x00, 0x00, 0xE8]
    assert_equal expected, uart.writes.first
  end

  def test_write_pos_with_zero_time_and_speed_means_max_speed
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 2)
    servo.write_pos(300, time_ms: 0, speed: 0)
    # pos=300=0x012C -> [0x2C, 0x01], time=0 -> [0,0], speed=0 -> [0,0]
    # sum = 2+9+3+0x2A+0x2C+1+0+0+0+0 = 2+9+3+42+44+1 = 101 = 0x65
    # checksum = ~0x65 & 0xFF = 0x9A
    expected = [0xFF, 0xFF, 0x02, 0x09, 0x03, 0x2A,
                0x2C, 0x01, 0x00, 0x00, 0x00, 0x00, 0x9A]
    assert_equal expected, uart.writes.first
  end

  def test_write_pos_signed_position_uses_sign_bit_high_byte
    # SCS encodes negative positions with bit 15 = sign on yaw raw scale.
    # For yaw -300, raw = 300 with sign bit set -> high byte 0x01 | 0x80 = 0x81
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(-300, time_ms: 0, speed: 0)
    expected_data = [0x2C, 0x81, 0x00, 0x00, 0x00, 0x00]
    actual_data = uart.writes.first[6, 6]
    assert_equal expected_data, actual_data
  end

  def test_read_pos_emits_request_packet
    uart = FakeUART.new
    # Pre-stage a valid response
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }
    servo = SCServo.new(uart, id: 1)
    servo.read_pos
    # request: ID=1, LEN=4, INSTR=2, REG=0x38, BYTES_TO_READ=2
    # sum=1+4+2+0x38+2 = 1+4+2+56+2 = 65 = 0x41 -> cksum=~0x41 & 0xFF = 0xBE
    expected_req = [0xFF, 0xFF, 0x01, 0x04, 0x02, 0x38, 0x02, 0xBE]
    assert_equal expected_req, uart.writes.first
  end

  def test_read_pos_returns_parsed_position
    uart = FakeUART.new
    # Response: pos = 0x01F4 = 500
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }
    servo = SCServo.new(uart, id: 1)
    assert_equal 500, servo.read_pos
  end

  def test_read_pos_decodes_negative
    uart = FakeUART.new
    # pos = 300 with sign bit -> [0x2C, 0x81], -> -300
    # Length and checksum recalc: ID=1, LEN=4, ERR=0, pos_L=0x2C, pos_H=0x81
    # sum=1+4+0+0x2C+0x81 = 1+4+44+129 = 178 = 0xB2 -> cksum=~0xB2 & 0xFF = 0x4D
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0x2C, 0x81, 0x4D] }
    servo = SCServo.new(uart, id: 1)
    assert_equal(-300, servo.read_pos)
  end

  def test_read_pos_returns_nil_on_timeout
    uart = FakeUART.new
    uart.read_queue << :timeout
    servo = SCServo.new(uart, id: 1)
    assert_nil servo.read_pos
  end

  def test_enable_torque_writes_reg_0x28_value_1
    uart = FakeUART.new
    SCServo.new(uart, id: 1).enable_torque
    # ID=1 LEN=4 INSTR=3 REG=0x28 DATA=1
    # sum=1+4+3+0x28+1 = 1+4+3+40+1 = 49 = 0x31 -> cksum=~0x31 & 0xFF = 0xCE
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x28, 0x01, 0xCE]
    assert_equal expected, uart.writes.first
  end

  def test_disable_torque_writes_reg_0x28_value_0
    uart = FakeUART.new
    SCServo.new(uart, id: 1).enable_torque(false)
    # sum=1+4+3+0x28+0 = 48 = 0x30 -> cksum = 0xCF
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x28, 0x00, 0xCF]
    assert_equal expected, uart.writes.first
  end

  def test_set_mode_position_writes_reg_0x21_value_0
    uart = FakeUART.new
    SCServo.new(uart, id: 1).set_mode(:position)
    # sum=1+4+3+0x21+0 = 1+4+3+33+0 = 41 = 0x29 -> cksum = 0xD6
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x21, 0x00, 0xD6]
    assert_equal expected, uart.writes.first
  end

  def test_set_mode_pwm_writes_reg_0x21_value_1
    uart = FakeUART.new
    SCServo.new(uart, id: 1).set_mode(:pwm)
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x21, 0x01, 0xD5]
    assert_equal expected, uart.writes.first
  end

  def test_set_mode_unknown_raises
    uart = FakeUART.new
    assert_raise(ArgumentError) do
      SCServo.new(uart, id: 1).set_mode(:wat)
    end
  end

  def test_write_pos_drains_pending_writepos_ack_bytes
    uart = FakeUART.new
    # Simulate two servos' WritePos ACKs accumulated in the line buffer
    uart.pending_rx = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC,
                       0xFF, 0xFF, 0x02, 0x02, 0x00, 0xFB]
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 0, speed: 0)
    # After write_pos, drain must have emptied pending_rx so subsequent read_pos
    # sees only the response we stage next.
    assert_empty uart.pending_rx
  end

  def test_read_pos_after_write_pos_isolates_response
    uart = FakeUART.new
    # stale bytes in pending_rx are cleared by clear_rx_buffer at the start of gen_write
    uart.pending_rx = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC]
    # write_pos TX echo (13 bytes) is drained by drain_echo; servo ACK follows
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC] }
    # read_pos TX echo (8 bytes) is drained by drain_echo; position response follows
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 0, speed: 0)
    assert_equal 500, servo.read_pos
  end

  def test_drain_echo_prevents_tx_echo_from_corrupting_read_pos
    # On a real half-duplex bus the master's 8-byte read request echoes back on RX.
    # FakeUART#write automatically adds those bytes to pending_rx to simulate this.
    # drain_echo must consume them before check_head reads the servo's actual response.
    uart = FakeUART.new
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }
    servo = SCServo.new(uart, id: 1)
    # Without drain_echo, check_head would parse the echo as the response → wrong value.
    assert_equal 500, servo.read_pos
  end

  def test_read_pos_raw_debug_returns_full_rx_bytes_as_hex
    uart = FakeUART.new
    # Stage a valid status packet response: FF FF 01 04 00 F4 01 05
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }
    servo = SCServo.new(uart, id: 1)
    raw = servo.read_pos_raw_debug
    assert_kind_of String, raw
    # Hex string of all bytes received on RX (echo + response)
    assert_match(/FF FF 01 04 00 F4 01 05/, raw)
  end

  def test_read_pos_raw_debug_returns_empty_marker_when_no_response
    # Production scenario: UART wiring does NOT loop back echo AND servo is unresponsive.
    # FakeUART.new(echo: false) simulates this case; must exercise the "<empty>" path.
    uart = FakeUART.new(echo: false)
    servo = SCServo.new(uart, id: 1)
    assert_equal "<empty>", servo.read_pos_raw_debug
  end

  def test_read_pos_raw_debug_returns_echo_bytes_when_no_servo_response
    # If servo doesn't respond but UART echo works, read_pos_raw_debug captures the TX echo.
    # This is a diagnostic value: confirm echo IS there (half-duplex working),
    # but servo's response is missing (servo problem, not line).
    uart = FakeUART.new(echo: true)
    servo = SCServo.new(uart, id: 1)
    raw = servo.read_pos_raw_debug
    assert_kind_of String, raw
    # Just the TX echo: ID=1, LEN=4, INSTR=2, REG=0x38, BYTES=2, cksum=0xBE
    assert_match(/FF FF 01 04 02 38 02 BE/, raw)
  end
end
