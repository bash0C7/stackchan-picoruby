class DispatcherServoTest < Picotest::Test
  class FakeServo
    attr_reader :writes
    attr_accessor :next_read
    def initialize; @writes = []; @next_read = 0; end
    def write_pos(pos, time_ms:, speed:); @writes << [pos, time_ms, speed]; end
    def read_pos; @next_read; end
  end

  class MiniSink
    attr_reader :writes
    def initialize; @writes = []; end
    def write(b); @writes << b; end
  end

  def setup
    @display = FakeDisplay.new
    @led     = FakeLed.new
    @stdout  = MiniSink.new
    @yaw_servo   = FakeServo.new
    @pitch_servo = FakeServo.new
    @head    = StackchanApp::Head.new(@yaw_servo, @pitch_servo)
    @disp    = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: @head
    )
  end

  def test_Y_frame_routes_to_yaw
    @yaw_servo.next_read = 332
    @pitch_servo.next_read = 781
    @disp.handle({ "YL" => "50", "PU" => "50", "T" => "2000" })
    # YL (StackChan's left) subtracts: 482 - 50*300/100 = 332; PU:50 → 633 + 50*296/100 = 781
    assert_equal [[332, 2000, 0]], @yaw_servo.writes
    assert_equal [[781, 2000, 0]], @pitch_servo.writes
  end

  # Direction regression guard: YR is StackChan's right,
  # raw ABOVE the forward zero — the opposite sign from YL.
  def test_YR_drives_opposite_sign_from_YL
    @disp.handle({ "YR" => "50", "T" => "1000" })
    assert_equal [[632, 1000, 0]], @yaw_servo.writes # 482 + 50*300/100
  end

  def test_YR_read_back_reports_YR_actual
    @yaw_servo.next_read   = 632   # 482 + 150 → YR:50
    @pitch_servo.next_read = 633   # zero → PU:0
    @disp.handle({ "YR" => "50" })
    assert_equal "<YR_actual:50,PU_actual:0>\n", @stdout.writes[1]
  end

  def test_servo_frame_emits_ack_byte_then_detail_frame
    # raw 332 → (482-332)*100/300 = YL:50 (below zero = StackChan's left);
    # raw 781 → (781-633)*100/296 = PU:50
    @yaw_servo.next_read = 332
    @pitch_servo.next_read = 781
    @disp.handle({ "YL" => "50", "PU" => "50" })
    # 1st write: ACK frame ".\n", 2nd write: detail frame "<YL_actual:50,PU_actual:50>\n"
    assert_equal ".\n", @stdout.writes[0]
    assert_equal "<YL_actual:50,PU_actual:50>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_nil_read_emits_error_frame
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = 781   # raw 781 → PU:50
    @disp.handle({ "YL" => "50", "PU" => "50" })
    assert_equal ".\n", @stdout.writes[0]
    assert_equal "<YL_actual:unknown,PU_actual:50>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_both_nil_axis_is_both
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = nil
    @disp.handle({ "YL" => "50", "PU" => "50" })
    assert_equal "<YL_actual:unknown,PU_actual:unknown>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_only_yaw_specified_still_reports_both_actuals
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = 633   # zero position (SERVO_PITCH_ZERO)
    @disp.handle({ "YL" => "50" })
    # New protocol always reports both axes; only YL was sent but both are output
    assert_equal "<YL_actual:unknown,PU_actual:0>\n", @stdout.writes[1]
  end

  def test_mixed_face_and_servo_frame_dispatches_both
    @yaw_servo.next_read = 332
    @pitch_servo.next_read = 781
    @disp.handle({ "F" => "0", "YL" => "50", "PU" => "50" })
    assert @display.calls.any? { |c| c.first == :draw_ellipse }
    assert_equal [[332, 0, 0]], @yaw_servo.writes
    assert_equal [[781, 0, 0]], @pitch_servo.writes
  end

  def test_dispatcher_without_head_returns_unavailable
    disp = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: nil
    )
    disp.handle({ "YL" => "50" })
    # ACK frame ".\n", detail frame with nil-head guard indicates unavailable
    assert_equal ".\n", @stdout.writes[0]
    assert_equal "<YL_actual:unknown,PU_actual:unknown>\n", @stdout.writes[1]
  end
end
