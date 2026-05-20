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
# Records all driver-facing calls so each test can assert on what the
# Dispatcher routed to the head. read_actual still uses string keys
# ("Y_actual" / "P_actual") for backward compatibility with existing
# servo tests; the symbol-key migration lands with Task 11 when the
# Dispatcher's emit_servo_detail is rewritten.
class FakeHead
  attr_accessor :fail_read
  attr_reader :torque_calls, :apply_calls, :selftest_calls

  def initialize(yaw_pos:, pitch_pos:)
    @yaw_pos        = yaw_pos
    @pitch_pos      = pitch_pos
    @fail_read      = false
    @torque_calls   = []
    @apply_calls    = []
    @selftest_calls = []
  end

  def apply(**kwargs)
    @apply_calls << kwargs
  end

  def enable_torque(on)
    @torque_calls << on
    true
  end

  def selftest
    @selftest_calls << true
    true
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

  def test_bad_face_index_emits_error_ack_frame
    @dispatcher.handle({ "F" => "99" })
    assert_equal ["?\n"], @stdout.frames
  end

  def test_torque_on_enables_torque_draws_neutral_and_acks
    @dispatcher.handle({ "torque" => "on" })
    assert_equal [true], @head.torque_calls
    assert_equal StackchanApp::Face::Neutral, @dispatcher.current_face_class
    assert_equal [".\n"], @stdout.frames
  end

  def test_torque_off_disables_torque_draws_closed_and_acks
    @dispatcher.handle({ "torque" => "off" })
    assert_equal [false], @head.torque_calls
    assert_equal StackchanApp::Face::Closed, @dispatcher.current_face_class
    assert_equal [".\n"], @stdout.frames
  end

  def test_torque_invalid_value_errors
    @dispatcher.handle({ "torque" => "maybe" })
    assert_equal ["?\n"], @stdout.frames
    assert_empty @head.torque_calls
  end

  def test_selftest_run_invokes_head_selftest_and_acks
    @dispatcher.handle({ "selftest" => "run" })
    assert_equal [true], @head.selftest_calls
    assert_equal [".\n"], @stdout.frames
  end

  def test_selftest_invalid_value_errors
    @dispatcher.handle({ "selftest" => "maybe" })
    assert_equal ["?\n"], @stdout.frames
    assert_empty @head.selftest_calls
  end

  def test_yl_50_converts_to_raw_above_zero_and_acks
    @dispatcher.handle({ "YL" => "50", "T" => "500" })
    assert_equal 1, @head.apply_calls.length
    call = @head.apply_calls.first
    assert_equal StackchanApp::Head::SERVO_YAW_ZERO + 25, call[:yaw_raw]
    assert_nil call[:pitch_raw]
    assert_equal 500, call[:time_ms]
  end

  def test_yr_50_converts_to_raw_below_zero
    @dispatcher.handle({ "YR" => "50" })
    call = @head.apply_calls.first
    assert_equal StackchanApp::Head::SERVO_YAW_ZERO - 25, call[:yaw_raw]
  end

  def test_pu_100_converts_to_raw_full_above_pitch_zero
    @dispatcher.handle({ "PU" => "100" })
    call = @head.apply_calls.first
    assert_equal StackchanApp::Head::SERVO_PITCH_ZERO + 30, call[:pitch_raw]
  end

  def test_yl_yr_conflict_uses_yl_ignores_yr
    @dispatcher.handle({ "YL" => "50", "YR" => "30" })
    call = @head.apply_calls.first
    assert_equal StackchanApp::Head::SERVO_YAW_ZERO + 25, call[:yaw_raw]
    # YR is silently ignored — YL wins
  end

  def test_yl_150_out_of_range_errors_no_apply
    @dispatcher.handle({ "YL" => "150" })
    assert_equal ["?\n"], @stdout.frames
    assert_empty @head.apply_calls
  end

  def test_pu_negative_out_of_range_errors_no_apply
    @dispatcher.handle({ "PU" => "-10" })
    assert_equal ["?\n"], @stdout.frames
    assert_empty @head.apply_calls
  end

  def test_yl_zero_emits_ack_and_centers_yaw
    @dispatcher.handle({ "YL" => "0" })
    call = @head.apply_calls.first
    assert_equal StackchanApp::Head::SERVO_YAW_ZERO, call[:yaw_raw]
  end
end
