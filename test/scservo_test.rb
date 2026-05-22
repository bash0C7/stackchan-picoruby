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
    # SCSCL big-endian (End=1):
    # pos=500=0x01F4 -> [0x01, 0xF4], time=1000=0x03E8 -> [0x03, 0xE8],
    # speed=0 -> [0x00, 0x00].
    # checksum = ~(1+9+3+0x2A+0x01+0xF4+0x03+0xE8+0+0) & 0xFF
    #         = ~(1+9+3+42+1+244+3+232+0+0) & 0xFF
    #         = ~0x17 & 0xFF = 0xE8
    expected = [0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A,
                0x01, 0xF4, 0x03, 0xE8, 0x00, 0x00, 0xE8]
    assert_equal expected, uart.writes.first
  end

  def test_write_pos_with_zero_time_and_speed_means_max_speed
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 2)
    servo.write_pos(300, time_ms: 0, speed: 0)
    # SCSCL big-endian: pos=300=0x012C -> [0x01, 0x2C], time/speed 0
    # sum = 2+9+3+0x2A+0x01+0x2C+0+0+0+0 = 2+9+3+42+1+44 = 101 = 0x65
    # checksum = ~0x65 & 0xFF = 0x9A
    expected = [0xFF, 0xFF, 0x02, 0x09, 0x03, 0x2A,
                0x01, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x9A]
    assert_equal expected, uart.writes.first
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
    # Verifies read_pos works after a preceding write_pos. clear_rx_buffer
    # is expected to drop any stale RX (here pre-staged stale bytes) before
    # the read flows, and the staged response feeds through unchanged
    # (no echo loopback on ESP32-S3 UART1 — Task 3 finding).
    uart.pending_rx = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC]
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC] }
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 0, speed: 0)
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

  def test_read_pos_retries_up_to_three_times_before_returning_nil
    uart = FakeUART.new
    # No response ever queued — all three attempts should drain to nil
    servo = SCServo.new(uart, id: 1)
    result = servo.read_pos
    assert_nil result
    # send_packet should have been called 3 times (3 retry attempts)
    assert_equal 3, uart.writes.length
  end

  def test_drain_echo_does_not_consume_rx_bytes
    uart = FakeUART.new
    uart.read_queue << { bytes: [0xAA, 0xBB, 0xCC] }
    servo = SCServo.new(uart, id: 1)
    servo.send(:drain_echo, 3)
    # All bytes still available
    assert_equal 3, uart.readpartial(3).bytesize
  end

  def test_read_pos_returns_value_on_second_attempt
    uart = FakeUART.new
    # First attempt: empty (queue empty), second attempt: valid response
    uart.read_queue_after_writes = {
      2 => [{ bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0xF4, 0x01, 0x05] }]
    }
    servo = SCServo.new(uart, id: 1)
    result = servo.read_pos
    assert_equal 500, result
    assert_equal 2, uart.writes.length
  end

  def test_encode_decode_word_round_trip_scscl_big_endian
    servo = SCServo.new(FakeUART.new, id: 1)
    # Round trip across the unsigned u16 domain.
    [0, 1, 255, 256, 500, 1023, 1024, 2048, 4095, 32768, 65535].each do |v|
      enc = servo.send(:encode_word, v)
      assert_equal 2, enc.length, "encode_word(#{v}) length"
      assert_equal v, servo.send(:decode_word, enc[0], enc[1]),
                   "round-trip mismatch for #{v}"
    end
    # SCSCL End=1: high byte goes on the wire first.
    assert_equal [0x01, 0xF4], servo.send(:encode_word, 500),
                 "encode_word(500) must be big-endian [hi, lo]"
    assert_equal 500, servo.send(:decode_word, 0x01, 0xF4),
                 "decode_word must treat first arg as high byte"
  end
end
