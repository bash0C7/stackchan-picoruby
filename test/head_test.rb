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
    @head.apply({ "Y" => "500" })
    assert_equal [[500, 0, 0]], @yaw.writes
    assert_empty @pitch.writes
  end

  def test_apply_with_P_only_writes_pitch_holds_yaw
    @head.apply({ "P" => "500" })
    assert_empty @yaw.writes
    assert_equal [[500, 0, 0]], @pitch.writes
  end

  def test_apply_with_T_overrides_V
    @head.apply({ "Y" => "100", "T" => "2000", "V" => "50" })
    assert_equal [[100, 2000, 0]], @yaw.writes
  end

  def test_apply_with_V_only_uses_velocity
    @head.apply({ "Y" => "100", "V" => "50" })
    assert_equal [[100, 0, 50]], @yaw.writes
  end

  def test_apply_with_neither_T_nor_V_means_max_speed
    @head.apply({ "Y" => "100" })
    assert_equal [[100, 0, 0]], @yaw.writes
  end

  def test_apply_clamps_yaw_above_max
    @head.apply({ "Y" => "9999" })
    assert_equal 1280, @yaw.writes.first[0]
  end

  def test_apply_clamps_yaw_below_min
    @head.apply({ "Y" => "-9999" })
    assert_equal(-1280, @yaw.writes.first[0])
  end

  def test_apply_clamps_pitch_above_max
    @head.apply({ "P" => "9999" })
    assert_equal 870, @pitch.writes.first[0]
  end

  def test_apply_clamps_pitch_below_min
    @head.apply({ "P" => "-100" })
    assert_equal 30, @pitch.writes.first[0]
  end

  def test_read_actual_returns_both_axes
    @yaw.next_read   = 123
    @pitch.next_read = 456
    assert_equal({ "Y_actual" => 123, "P_actual" => 456 }, @head.read_actual)
  end

  def test_read_actual_propagates_nil
    @yaw.next_read   = nil
    @pitch.next_read = 500
    assert_equal({ "Y_actual" => nil, "P_actual" => 500 }, @head.read_actual)
  end
end
