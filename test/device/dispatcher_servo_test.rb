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

  def test_YL50_PU50_writes_yaw_482_minus_150_and_pitch_633_plus_148
    @yaw_servo.next_read = 332
    @pitch_servo.next_read = 781
    @disp.handle({ "YL" => "50", "PU" => "50", "T" => "2000" })
    assert_equal [[332, 2000, 0]], @yaw_servo.writes
    assert_equal [[781, 2000, 0]], @pitch_servo.writes
  end

  def test_YR50_writes_yaw_above_the_forward_zero_opposite_to_YL
    @disp.handle({ "YR" => "50", "T" => "1000" })
    assert_equal [[632, 1000, 0]], @yaw_servo.writes
  end

  def test_YR_read_back_reports_YR_actual
    @yaw_servo.next_read   = 632
    @pitch_servo.next_read = 633
    @disp.handle({ "YR" => "50" })
    assert_equal "<YR_actual:50,PU_actual:0>\n", @stdout.writes[1]
  end

  def test_servo_frame_emits_ack_byte_then_detail_frame
    @yaw_servo.next_read = 332
    @pitch_servo.next_read = 781
    @disp.handle({ "YL" => "50", "PU" => "50" })
    assert_equal ".\n", @stdout.writes[0]
    assert_equal "<YL_actual:50,PU_actual:50>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_nil_yaw_read_acks_and_reports_YL_actual_unknown
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = 781
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
    @pitch_servo.next_read = 633
    @disp.handle({ "YL" => "50" })
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

  def test_servo_frame_with_an_unknown_face_answers_error_and_no_detail
    @disp.handle({ "F" => "9", "YL" => "50" })
    assert_equal ["?\n"], @stdout.writes
  end

  def test_servo_frame_without_head_acks_and_reports_both_axes_unknown
    disp = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: nil
    )
    disp.handle({ "YL" => "50" })
    assert_equal ".\n", @stdout.writes[0]
    assert_equal "<YL_actual:unknown,PU_actual:unknown>\n", @stdout.writes[1]
  end
end
