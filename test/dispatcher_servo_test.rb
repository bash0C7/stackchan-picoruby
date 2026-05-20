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
    omit "deferred to Task 12 rewrite (file targets direction-key YL/YR/PU syntax)"
  end

  def test_servo_frame_emits_ack_byte_then_detail_frame
    omit "deferred to Task 12 rewrite (file targets direction-key YL/YR/PU syntax)"
  end

  def test_servo_frame_with_nil_read_emits_error_frame
    omit "deferred to Task 12 rewrite (file targets direction-key YL/YR/PU syntax)"
  end

  def test_servo_frame_with_both_nil_axis_is_both
    omit "deferred to Task 12 rewrite (file targets direction-key YL/YR/PU syntax)"
  end

  def test_servo_frame_with_only_yaw_specified_only_yaw_axis_in_error
    omit "deferred to Task 12 rewrite (file targets direction-key YL/YR/PU syntax)"
  end

  def test_mixed_face_and_servo_frame_dispatches_both
    omit "deferred to Task 12 rewrite (file targets direction-key YL/YR/PU syntax)"
  end

  def test_dispatcher_without_head_returns_unavailable
    omit "deferred to Task 12 rewrite (file targets direction-key YL/YR/PU syntax)"
  end
end
