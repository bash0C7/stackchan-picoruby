class SCServoTest < Picotest::Test
  def test_initializes_with_uart_and_id
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    assert(servo.is_a?(SCServo))
  end

  def test_write_pos_emits_correct_packet
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 1000, speed: 0)
    expected = [0xFF, 0xFF, 0x01, 0x09, 0x03, 0x2A,
                0x01, 0xF4, 0x03, 0xE8, 0x00, 0x00, 0xE8]
    assert_equal expected, uart.writes.first
  end

  def test_write_pos_with_zero_time_and_speed_means_max_speed
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 2)
    servo.write_pos(300, time_ms: 0, speed: 0)
    expected = [0xFF, 0xFF, 0x02, 0x09, 0x03, 0x2A,
                0x01, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x9A]
    assert_equal expected, uart.writes.first
  end

  def test_read_pos_emits_request_packet
    uart = FakeUART.new
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0x01, 0xF4, 0x05] }
    servo = SCServo.new(uart, id: 1)
    servo.read_pos
    expected_req = [0xFF, 0xFF, 0x01, 0x04, 0x02, 0x38, 0x02, 0xBE]
    assert_equal expected_req, uart.writes.first
  end

  def test_read_pos_returns_parsed_position
    uart = FakeUART.new
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0x01, 0xF4, 0x05] }
    servo = SCServo.new(uart, id: 1)
    assert_equal 500, servo.read_pos
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
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x28, 0x01, 0xCE]
    assert_equal expected, uart.writes.first
  end

  def test_disable_torque_writes_reg_0x28_value_0
    uart = FakeUART.new
    SCServo.new(uart, id: 1).enable_torque(false)
    expected = [0xFF, 0xFF, 0x01, 0x04, 0x03, 0x28, 0x00, 0xCF]
    assert_equal expected, uart.writes.first
  end

  def test_set_mode_position_writes_reg_0x21_value_0
    uart = FakeUART.new
    SCServo.new(uart, id: 1).set_mode(:position)
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
    uart.pending_rx = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC,
                       0xFF, 0xFF, 0x02, 0x02, 0x00, 0xFB]
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 0, speed: 0)
    assert(uart.pending_rx.empty?)
  end

  def test_read_pos_after_write_pos_isolates_response
    uart = FakeUART.new
    uart.pending_rx = [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC]
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x02, 0x00, 0xFC] }
    uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0x01, 0xF4, 0x05] }
    servo = SCServo.new(uart, id: 1)
    servo.write_pos(500, time_ms: 0, speed: 0)
    assert_equal 500, servo.read_pos
  end

  def test_read_pos_retries_up_to_three_times_before_returning_nil
    uart = FakeUART.new
    servo = SCServo.new(uart, id: 1)
    result = servo.read_pos
    assert_nil result
    assert_equal 3, uart.writes.length
  end

  def test_read_pos_returns_value_on_second_attempt
    uart = FakeUART.new
    uart.read_queue_after_writes = {
      2 => [{ bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0x01, 0xF4, 0x05] }]
    }
    servo = SCServo.new(uart, id: 1)
    result = servo.read_pos
    assert_equal 500, result
    assert_equal 2, uart.writes.length
  end

  def test_encode_decode_word_round_trip_scscl_big_endian
    servo = SCServo.new(FakeUART.new, id: 1)
    [0, 1, 255, 256, 500, 1023, 1024, 2048, 4095, 32768, 65535].each do |v|
      enc = servo.send(:encode_word, v)
      assert_equal 2, enc.length
      assert_equal v, servo.send(:decode_word, enc[0], enc[1])
    end
    assert_equal [0x01, 0xF4], servo.send(:encode_word, 500)
    assert_equal 500, servo.send(:decode_word, 0x01, 0xF4)
  end
end
