require_relative "test_helper"
require_relative "fake_stdio"

# Load Dispatcher (and Face classes) from application.rb via Prism AST extractor,
# excluding StackChanApp < BLE which cannot run on host.
require_relative "../../../lib/ruby_class_extract"
RubyClassExtract.load_classes_from(
  File.expand_path("../examples/application.rb", __dir__),
  exclude_superclasses: ["BLE"]
)

# Minimal FakeHead for Dispatcher host tests.
# Simulates a servo head: #apply records the command, #read_actual returns
# the positions given at construction (or nil for both axes when fail_read=true).
class FakeHead
  attr_accessor :fail_read

  def initialize(yaw_pos:, pitch_pos:)
    @yaw_pos   = yaw_pos
    @pitch_pos = pitch_pos
    @fail_read = false
  end

  def apply(_frame)
    # no-op for host tests
  end

  def read_actual
    return { "Y_actual" => nil, "P_actual" => nil } if @fail_read
    { "Y_actual" => @yaw_pos, "P_actual" => @pitch_pos }
  end
end

class TestDispatcherFrameContract < Test::Unit::TestCase
  def setup
    @stdout = FakeStdio.new
    @display = FakeDisplay.new
    @led = FakeLed.new
    @head = FakeHead.new(yaw_pos: 0, pitch_pos: 600)
    @dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: @head
    )
  end

  def test_face_frame_emits_one_ack_frame_with_newline
    @dispatcher.handle({ "F" => "2" })
    assert_equal [".\n"], @stdout.frames
  end

  def test_servo_frame_emits_ack_frame_then_detail_frame
    @dispatcher.handle({ "Y" => "0", "P" => "600", "T" => "250" })
    assert_equal [".\n", "<Y_actual:0,P_actual:600>\n"], @stdout.frames
  end

  def test_servo_timeout_emits_ack_then_error_detail_frame
    @head.fail_read = true
    @dispatcher.handle({ "Y" => "0", "P" => "600", "T" => "250" })
    assert_equal [".\n", "<ERROR:servo_timeout,axis:both>\n"], @stdout.frames
  end

  def test_bad_face_index_emits_error_ack_frame
    @dispatcher.handle({ "F" => "99" })
    assert_equal ["?\n"], @stdout.frames
  end
end
