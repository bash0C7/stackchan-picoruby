$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class DispatcherServoTest < Test::Unit::TestCase
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
    @yaw_servo.next_read = 498
    @pitch_servo.next_read = 500
    @disp.handle({ "Y" => "-300", "P" => "500", "T" => "2000" })
    assert_equal [[-300, 2000, 0]], @yaw_servo.writes
    assert_equal [[500,  2000, 0]], @pitch_servo.writes
  end

  def test_servo_frame_emits_ack_byte_then_detail_frame
    @yaw_servo.next_read = 498
    @pitch_servo.next_read = 500
    @disp.handle({ "Y" => "-300", "P" => "500" })
    # 1st write: ACK frame ".\n", 2nd write: detail frame "<Y_actual:498,P_actual:500>\n"
    assert_equal ".\n", @stdout.writes[0]
    assert_equal "<Y_actual:498,P_actual:500>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_nil_read_emits_error_frame
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = 500
    @disp.handle({ "Y" => "-300", "P" => "500" })
    assert_equal ".\n", @stdout.writes[0]
    assert_equal "<ERROR:servo_timeout,axis:yaw>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_both_nil_axis_is_both
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = nil
    @disp.handle({ "Y" => "-300", "P" => "500" })
    assert_equal "<ERROR:servo_timeout,axis:both>\n", @stdout.writes[1]
  end

  def test_servo_frame_with_only_yaw_specified_only_yaw_axis_in_error
    @yaw_servo.next_read   = nil
    @pitch_servo.next_read = 500   # but pitch wasn't asked
    @disp.handle({ "Y" => "-300" })
    # Only Y is in the frame; pitch wasn't requested even if its read_pos is fine
    assert_equal "<ERROR:servo_timeout,axis:yaw>\n", @stdout.writes[1]
  end

  def test_mixed_face_and_servo_frame_dispatches_both
    @yaw_servo.next_read = 100
    @pitch_servo.next_read = 200
    @disp.handle({ "F" => "0", "Y" => "100", "P" => "200" })
    assert @display.calls.any? { |c| c.first == :draw_ellipse }
    assert_equal [[100, 0, 0]], @yaw_servo.writes
    assert_equal [[200, 0, 0]], @pitch_servo.writes
  end

  def test_dispatcher_without_head_returns_unavailable
    disp = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: nil
    )
    disp.handle({ "Y" => "100" })
    # ACK frame ".\n", detail frame indicates unavailable
    assert_equal ".\n", @stdout.writes[0]
    assert_equal "<ERROR:servo_unavailable>\n", @stdout.writes[1]
  end
end
