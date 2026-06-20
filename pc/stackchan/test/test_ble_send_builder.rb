require_relative "test_helper"
require "stackchan/ble"

class SendBuilderBasicTest < Test::Unit::TestCase
  def test_face_only
    b = Stackchan::BLE::SendBuilder.new
    b.face(:joy)
    assert_equal ["<F:2>\n"], b.to_frames
  end

  def test_led_named_default_side_both_mode_solid
    b = Stackchan::BLE::SendBuilder.new
    b.led(:red)
    assert_equal ["<L:1,R:255,G:0,B:0,S:B,M:s>\n"], b.to_frames
  end

  def test_led_named_with_mode
    b = Stackchan::BLE::SendBuilder.new
    b.led(:blue, mode: :blink)
    assert_equal ["<L:1,R:0,G:0,B:255,S:B,M:b>\n"], b.to_frames
  end

  def test_led_named_with_side
    b = Stackchan::BLE::SendBuilder.new
    b.led(:green, side: :left)
    # API :left = StackChan's left hand = wire "R"
    assert_equal ["<L:1,R:0,G:255,B:0,S:R,M:s>\n"], b.to_frames
  end

  def test_led_rgb_form
    b = Stackchan::BLE::SendBuilder.new
    b.led(:rgb, 0xFF8000)
    assert_equal ["<L:1,R:255,G:128,B:0,S:B,M:s>\n"], b.to_frames
  end

  def test_led_hsb_form_red
    b = Stackchan::BLE::SendBuilder.new
    b.led(:hsb, 0x00FFFF) # H=0, S=255, B=255 → pure red
    assert_equal ["<L:1,R:255,G:0,B:0,S:B,M:s>\n"], b.to_frames
  end
end

class SendBuilderAggregationTest < Test::Unit::TestCase
  def test_same_method_same_side_last_wins
    b = Stackchan::BLE::SendBuilder.new
    b.led(:red)
    b.led(:blue)        # both → blue
    assert_equal ["<L:1,R:0,G:0,B:255,S:B,M:s>\n"], b.to_frames
  end

  def test_different_sides_independent
    b = Stackchan::BLE::SendBuilder.new
    b.led(:red,   side: :left)
    b.led(:blue,  side: :right)
    # API :left → wire "R", :right → wire "L" (StackChan-perspective)
    assert_equal [
      "<L:1,R:255,G:0,B:0,S:R,M:s>\n",
      "<L:1,R:0,G:0,B:255,S:L,M:s>\n",
    ], b.to_frames
  end

  def test_face_and_led_in_order_of_first_appearance
    b = Stackchan::BLE::SendBuilder.new
    b.face(:joy)
    b.led(:red)
    b.led(:blue)
    assert_equal [
      "<F:2>\n",
      "<L:1,R:0,G:0,B:255,S:B,M:s>\n",
    ], b.to_frames
  end

  def test_led_first_then_face_preserves_first_occurrence_order
    b = Stackchan::BLE::SendBuilder.new
    b.led(:red)
    b.face(:smile)
    assert_equal [
      "<L:1,R:255,G:0,B:0,S:B,M:s>\n",
      "<F:1>\n",
    ], b.to_frames
  end

  def test_max_4_frames
    b = Stackchan::BLE::SendBuilder.new
    b.face(:joy)
    b.led(:red,  side: :both)
    b.led(:blue, side: :left)
    b.led(:green, side: :right)
    # add more — should not exceed 4
    b.face(:smile)
    b.led(:white, side: :both, mode: :blink)
    frames = b.to_frames
    assert_equal 4, frames.size
    assert_includes frames, "<F:1>\n"
    assert_includes frames, "<L:1,R:255,G:255,B:255,S:B,M:b>\n"
    assert_includes frames, "<L:1,R:0,G:0,B:255,S:R,M:s>\n"
    assert_includes frames, "<L:1,R:0,G:255,B:0,S:L,M:s>\n"
  end

  def test_form_can_switch_with_last_wins
    b = Stackchan::BLE::SendBuilder.new
    b.led(:red)
    b.led(:rgb, 0xFF8000)  # overrides
    assert_equal ["<L:1,R:255,G:128,B:0,S:B,M:s>\n"], b.to_frames
  end

  def test_unknown_form_raises
    b = Stackchan::BLE::SendBuilder.new
    assert_raise(ArgumentError) do
      b.led(:not_a_form, 0x123456)
      b.to_frames
    end
  end
end

class SendBuilderHeadTest < Test::Unit::TestCase
  def test_head_with_yaw_left
    builder = Stackchan::BLE::SendBuilder.new
    builder.head(yaw_left: 50, time_ms: 500)
    assert_equal ["<YL:50,T:500>\n"], builder.to_frames
  end

  def test_head_with_yaw_right_and_pitch_up
    builder = Stackchan::BLE::SendBuilder.new
    builder.head(yaw_right: 30, pitch_up: 80)
    assert_equal ["<YR:30,PU:80>\n"], builder.to_frames
  end

  def test_head_last_wins_for_same_key
    builder = Stackchan::BLE::SendBuilder.new
    builder.head(yaw_left: 50)
    builder.head(yaw_right: 30, pitch_up: 80, time_ms: 1000)
    assert_equal ["<YR:30,PU:80,T:1000>\n"], builder.to_frames
  end

  def test_head_coexists_with_face_and_led_in_first_occurrence_order
    builder = Stackchan::BLE::SendBuilder.new
    builder.face(:joy)
    builder.head(yaw_left: 0, pitch_up: 50)
    builder.led(:red)
    assert_equal [
      "<F:2>\n",
      "<YL:0,PU:50>\n",
      "<L:1,R:255,G:0,B:0,S:B,M:s>\n",
    ], builder.to_frames
  end
end

class SendBuilderTorqueTest < Test::Unit::TestCase
  def test_torque_on
    builder = Stackchan::BLE::SendBuilder.new
    builder.torque(on: true)
    assert_equal ["<torque:on>\n"], builder.to_frames
  end

  def test_torque_off
    builder = Stackchan::BLE::SendBuilder.new
    builder.torque(on: false)
    assert_equal ["<torque:off>\n"], builder.to_frames
  end
end

class SendBuilderSelftestTest < Test::Unit::TestCase
  def test_selftest
    builder = Stackchan::BLE::SendBuilder.new
    builder.selftest
    assert_equal ["<selftest:run>\n"], builder.to_frames
  end
end

class SendBuilderReadPosTest < Test::Unit::TestCase
  def test_read_pos
    builder = Stackchan::BLE::SendBuilder.new
    builder.read_pos
    assert_equal ["<read:pos>\n"], builder.to_frames
  end
end
