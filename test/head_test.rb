$LOAD_PATH.unshift(File.expand_path('.', __dir__))
require 'test_helper'

class HeadTest < Test::Unit::TestCase
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
    @head  = StackchanApp::Head.new(@yaw, @pitch)
  end

  def test_apply_with_Y_only_writes_yaw_holds_pitch
    @head.apply(yaw_raw: 500)
    assert_equal [[500, 0, 0]], @yaw.writes
    assert_empty @pitch.writes
  end

  def test_apply_with_P_only_writes_pitch_holds_yaw
    @head.apply(pitch_raw: 500)
    assert_empty @yaw.writes
    assert_equal [[500, 0, 0]], @pitch.writes
  end

  def test_apply_with_T_overrides_V
    omit "obsolete: T/V protocol logic moved to Dispatcher frame parsing in Task 10"
  end

  def test_apply_with_V_only_uses_velocity
    @head.apply(yaw_raw: 100, velocity: 50)
    assert_equal [[100, 0, 50]], @yaw.writes
  end

  def test_apply_with_neither_T_nor_V_means_max_speed
    @head.apply(yaw_raw: 100)
    assert_equal [[100, 0, 0]], @yaw.writes
  end

  def test_apply_clamps_yaw_above_max
    omit "obsolete: clamp moved to Dispatcher#handle_head in Task 10"
  end

  def test_apply_clamps_yaw_below_min
    omit "obsolete: clamp moved to Dispatcher#handle_head in Task 10"
  end

  def test_apply_clamps_pitch_above_max
    omit "obsolete: clamp moved to Dispatcher#handle_head in Task 10"
  end

  def test_apply_clamps_pitch_below_min
    omit "obsolete: clamp moved to Dispatcher#handle_head in Task 10"
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
end
