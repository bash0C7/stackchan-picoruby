class HeadTest < Picotest::Test
  class FakeServo
    attr_reader :writes
    attr_accessor :next_read
    def initialize; @writes = []; @next_read = 0; end
    def write_pos(pos, time_ms:, speed:); @writes << [pos, time_ms, speed]; end
    def read_pos; @next_read; end
  end

  def setup
    @yaw   = FakeServo.new
    @pitch = FakeServo.new
    @head  = StackChan::Robot::Head.new(@yaw, @pitch)
  end

  def test_apply_with_Y_only_writes_yaw_holds_pitch
    @head.apply(yaw_raw: 500)
    assert_equal [[500, 0, 0]], @yaw.writes
    assert(@pitch.writes.empty?)
  end

  def test_apply_with_P_only_writes_pitch_holds_yaw
    @head.apply(pitch_raw: 500)
    assert(@yaw.writes.empty?)
    assert_equal [[500, 0, 0]], @pitch.writes
  end


  def test_apply_with_V_only_uses_velocity
    @head.apply(yaw_raw: 100, velocity: 50)
    assert_equal [[100, 0, 50]], @yaw.writes
  end

  def test_apply_with_neither_T_nor_V_means_max_speed
    @head.apply(yaw_raw: 100)
    assert_equal [[100, 0, 0]], @yaw.writes
  end





  def test_read_actual_returns_both_axes
    @yaw.next_read   = 123
    @pitch.next_read = 456
    assert_equal({ yaw: 123, pitch: 456 }, @head.read_actual)
  end

  def test_read_actual_propagates_nil
    @yaw.next_read   = nil
    @pitch.next_read = 500
    assert_equal({ yaw: nil, pitch: 500 }, @head.read_actual)
  end

  def test_read_health_reports_the_real_scservos_error_and_status_per_axis
    yaw_uart = FakeUART.new
    yaw_uart.read_queue << :timeout
    pitch_uart = FakeUART.new
    pitch_uart.read_queue << { bytes: [0xFF, 0xFF, 0x01, 0x04, 0x00, 0x01, 0xF4, 0x05] }
    head = StackChan::Robot::Head.new(SCServo.new(yaw_uart, id: 1), SCServo.new(pitch_uart, id: 1))
    head.read_actual
    assert_equal({ yaw: [:no_header, nil], pitch: [nil, 0] }, head.read_health)
  end
end
