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
# Dispatcher routed to the head. read_actual now uses symbol keys (:yaw, :pitch)
# matching the Head#read_actual contract from Task 10.
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
    return { yaw: nil, pitch: nil } if @fail_read
    { yaw: @yaw_pos, pitch: @pitch_pos }
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

  def test_selftest_run_invokes_head_selftest_and_acks_with_detail
    @dispatcher.handle({ "selftest" => "run" })
    assert_equal [true], @head.selftest_calls
    assert_equal 2, @stdout.frames.length
    assert_equal ".\n", @stdout.frames[0]
    assert_match(/\A<(YL|YR)_actual:\d+,PU_actual:\d+>\n\z/, @stdout.frames[1])
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

  def test_detail_reports_yl_actual_when_raw_above_zero
    @head = FakeHead.new(yaw_pos: StackchanApp::Head::SERVO_YAW_ZERO + 25,
                         pitch_pos: StackchanApp::Head::SERVO_PITCH_ZERO + 9)
    @dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: @head
    )
    @dispatcher.handle({ "YL" => "50", "PU" => "30" })
    detail = @stdout.frames.last
    # raw +25 = 50% of YAW_RANGE_RAW=50 → YL_actual:50
    # raw +9  = 30% of PITCH_RANGE_RAW=30 → PU_actual:30
    assert_equal "<YL_actual:50,PU_actual:30>\n", detail
  end

  def test_detail_reports_yr_actual_when_raw_below_zero
    @head = FakeHead.new(yaw_pos: StackchanApp::Head::SERVO_YAW_ZERO - 15,
                         pitch_pos: StackchanApp::Head::SERVO_PITCH_ZERO)
    @dispatcher = StackchanApp::Dispatcher.new(
      display: @display, led: @led, stdout: @stdout, head: @head
    )
    @dispatcher.handle({ "YR" => "30" })
    detail = @stdout.frames.last
    # raw -15 → 30% magnitude on YR side → YR_actual:30, PU_actual:0
    assert_equal "<YR_actual:30,PU_actual:0>\n", detail
  end

  def test_detail_reports_unknown_when_read_actual_nil
    @head.fail_read = true
    @dispatcher.handle({ "YL" => "50" })
    detail = @stdout.frames.last
    assert_equal "<YL_actual:unknown,PU_actual:unknown>\n", detail
  end
end
