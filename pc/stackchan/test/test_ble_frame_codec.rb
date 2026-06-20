require_relative "test_helper"
require "stackchan/ble"

class FrameCodecEncodeFaceTest < Test::Unit::TestCase
  def test_encode_face_neutral
    assert_equal "<F:0>\n", Stackchan::BLE::FrameCodec.encode_face(face_name: :neutral)
  end

  def test_encode_face_joy
    assert_equal "<F:2>\n", Stackchan::BLE::FrameCodec.encode_face(face_name: :joy)
  end

  def test_encode_face_unknown_raises
    assert_raise(KeyError) do
      Stackchan::BLE::FrameCodec.encode_face(face_name: :bogus)
    end
  end
end

class FrameCodecEncodeLedTest < Test::Unit::TestCase
  def test_encode_led_both_red_solid
    assert_equal "<L:1,R:255,G:0,B:0,S:B,M:s>\n",
                 Stackchan::BLE::FrameCodec.encode_led(r: 255, g: 0, b: 0, side: :both, mode: :solid)
  end

  def test_encode_led_left_blue_blink
    # API :left = StackChan's left hand = wire "R" (see SIDE_TO_CHAR comment)
    assert_equal "<L:1,R:0,G:0,B:255,S:R,M:b>\n",
                 Stackchan::BLE::FrameCodec.encode_led(r: 0, g: 0, b: 255, side: :left, mode: :blink)
  end

  def test_encode_led_right_yellow_breathing
    # API :right = StackChan's right hand = wire "L"
    assert_equal "<L:1,R:255,G:255,B:0,S:L,M:p>\n",
                 Stackchan::BLE::FrameCodec.encode_led(r: 255, g: 255, b: 0, side: :right, mode: :breathing)
  end

  def test_encode_led_off_includes_rgb_as_zeros
    assert_equal "<L:1,R:0,G:0,B:0,S:B,M:o>\n",
                 Stackchan::BLE::FrameCodec.encode_led(r: 0, g: 0, b: 0, side: :both, mode: :off)
  end

  def test_encode_led_unknown_side_raises
    assert_raise(ArgumentError) do
      Stackchan::BLE::FrameCodec.encode_led(r: 0, g: 0, b: 0, side: :up, mode: :solid)
    end
  end

  def test_encode_led_unknown_mode_raises
    assert_raise(ArgumentError) do
      Stackchan::BLE::FrameCodec.encode_led(r: 0, g: 0, b: 0, side: :both, mode: :strobe)
    end
  end
end

class FrameCodecHeadTest < Test::Unit::TestCase
  def test_encode_head_yaw_left
    result = Stackchan::BLE::FrameCodec.encode_head(
      yaw_left: 50, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil
    )
    assert_equal "<YL:50>\n", result
  end

  def test_encode_head_yaw_right_pitch_up_and_time
    result = Stackchan::BLE::FrameCodec.encode_head(
      yaw_left: nil, yaw_right: 30, pitch_up: 80, time_ms: 500, velocity: nil
    )
    assert_equal "<YR:30,PU:80,T:500>\n", result
  end

  def test_encode_head_yaw_left_zero_means_center
    result = Stackchan::BLE::FrameCodec.encode_head(
      yaw_left: 0, yaw_right: nil, pitch_up: 0, time_ms: nil, velocity: nil
    )
    assert_equal "<YL:0,PU:0>\n", result
  end

  def test_encode_head_raises_when_all_axes_nil
    assert_raise(ArgumentError) do
      Stackchan::BLE::FrameCodec.encode_head(
        yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil, velocity: nil
      )
    end
  end

  def test_encode_head_raises_when_yaw_left_and_right_both_set
    assert_raise(ArgumentError) do
      Stackchan::BLE::FrameCodec.encode_head(
        yaw_left: 50, yaw_right: 30, pitch_up: nil, time_ms: nil, velocity: nil
      )
    end
  end
end

class FrameCodecTorqueTest < Test::Unit::TestCase
  def test_encode_torque_on
    assert_equal "<torque:on>\n", Stackchan::BLE::FrameCodec.encode_torque(on: true)
  end

  def test_encode_torque_off
    assert_equal "<torque:off>\n", Stackchan::BLE::FrameCodec.encode_torque(on: false)
  end
end

class FrameCodecSelftestTest < Test::Unit::TestCase
  def test_encode_selftest
    assert_equal "<selftest:run>\n", Stackchan::BLE::FrameCodec.encode_selftest
  end
end

class FrameCodecReadPosTest < Test::Unit::TestCase
  def test_encode_read_pos
    assert_equal "<read:pos>\n", Stackchan::BLE::FrameCodec.encode_read_pos
  end
end

class FrameCodecAckTest < Test::Unit::TestCase
  def test_ack_ok_byte
    assert_equal :ok, Stackchan::BLE::FrameCodec.parse_ack(".")
  end

  def test_ack_error_byte
    assert_equal :error, Stackchan::BLE::FrameCodec.parse_ack("?")
  end

  def test_unknown_ack_frame_raises
    assert_raise(ArgumentError) do
      Stackchan::BLE::FrameCodec.parse_ack("X")
    end
  end

  def test_parse_ack_accepts_newline_terminated_ok_frame
    assert_equal :ok, Stackchan::BLE::FrameCodec.parse_ack(".\n")
  end

  def test_parse_ack_accepts_newline_terminated_error_frame
    assert_equal :error, Stackchan::BLE::FrameCodec.parse_ack("?\n")
  end

  def test_parse_ack_rejects_frame_starting_with_unknown_byte
    assert_raise(ArgumentError) { Stackchan::BLE::FrameCodec.parse_ack("<YL_actual:0,PU_actual:50>\n") }
  end
end

class FrameCodecTest < Test::Unit::TestCase
  def test_touch_event_true_only_for_touch_frames
    assert_true  Stackchan::BLE::FrameCodec.touch_event?("<touch:1>\n")
    assert_false Stackchan::BLE::FrameCodec.touch_event?(".\n")
    assert_false Stackchan::BLE::FrameCodec.touch_event?("<YL_actual:0,PU_actual:50>\n")
  end

  def test_parse_touch_returns_zone_integer_or_nil
    assert_equal 2,   Stackchan::BLE::FrameCodec.parse_touch("<touch:2>\n")
    assert_nil        Stackchan::BLE::FrameCodec.parse_touch(".\n")
  end
end
