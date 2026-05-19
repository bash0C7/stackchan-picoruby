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
end
