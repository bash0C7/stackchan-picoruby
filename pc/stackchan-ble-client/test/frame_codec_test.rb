require "test_helper"

class FrameCodecEncodeFaceTest < Test::Unit::TestCase
  def test_encode_face_neutral
    assert_equal "<F:0>\n", StackchanBleClient::FrameCodec.encode_face(face_name: :neutral)
  end

  def test_encode_face_joy
    assert_equal "<F:2>\n", StackchanBleClient::FrameCodec.encode_face(face_name: :joy)
  end

  def test_encode_face_unknown_raises
    assert_raise(KeyError) do
      StackchanBleClient::FrameCodec.encode_face(face_name: :bogus)
    end
  end
end

class FrameCodecEncodeLedTest < Test::Unit::TestCase
  def test_encode_led_both_red_solid
    assert_equal "<L:1,R:255,G:0,B:0,S:B,M:s>\n",
                 StackchanBleClient::FrameCodec.encode_led(r: 255, g: 0, b: 0, side: :both, mode: :solid)
  end

  def test_encode_led_left_blue_blink
    # API :left = StackChan's left hand = wire "R" (see SIDE_TO_CHAR comment)
    assert_equal "<L:1,R:0,G:0,B:255,S:R,M:b>\n",
                 StackchanBleClient::FrameCodec.encode_led(r: 0, g: 0, b: 255, side: :left, mode: :blink)
  end

  def test_encode_led_right_yellow_breathing
    # API :right = StackChan's right hand = wire "L"
    assert_equal "<L:1,R:255,G:255,B:0,S:L,M:p>\n",
                 StackchanBleClient::FrameCodec.encode_led(r: 255, g: 255, b: 0, side: :right, mode: :breathing)
  end

  def test_encode_led_off_includes_rgb_as_zeros
    assert_equal "<L:1,R:0,G:0,B:0,S:B,M:o>\n",
                 StackchanBleClient::FrameCodec.encode_led(r: 0, g: 0, b: 0, side: :both, mode: :off)
  end

  def test_encode_led_unknown_side_raises
    assert_raise(ArgumentError) do
      StackchanBleClient::FrameCodec.encode_led(r: 0, g: 0, b: 0, side: :up, mode: :solid)
    end
  end

  def test_encode_led_unknown_mode_raises
    assert_raise(ArgumentError) do
      StackchanBleClient::FrameCodec.encode_led(r: 0, g: 0, b: 0, side: :both, mode: :strobe)
    end
  end
end

class FrameCodecHeadTest < Test::Unit::TestCase
  def test_encode_head_all_axes_and_time
    out = StackchanBleClient::FrameCodec.encode_head(
      yaw: -300, pitch: 500, time_ms: 2000, velocity: nil
    )
    assert_equal "<Y:-300,P:500,T:2000>\n", out
  end

  def test_encode_head_with_velocity
    out = StackchanBleClient::FrameCodec.encode_head(
      yaw: 100, pitch: nil, time_ms: nil, velocity: 50
    )
    assert_equal "<Y:100,V:50>\n", out
  end

  def test_encode_head_yaw_only_no_time_no_velocity
    out = StackchanBleClient::FrameCodec.encode_head(
      yaw: 0, pitch: nil, time_ms: nil, velocity: nil
    )
    assert_equal "<Y:0>\n", out
  end

  def test_encode_head_pitch_only
    out = StackchanBleClient::FrameCodec.encode_head(
      yaw: nil, pitch: 500, time_ms: nil, velocity: nil
    )
    assert_equal "<P:500>\n", out
  end

  def test_encode_head_neither_axis_raises
    assert_raise(ArgumentError) do
      StackchanBleClient::FrameCodec.encode_head(
        yaw: nil, pitch: nil, time_ms: 100, velocity: nil
      )
    end
  end

  def test_encode_head_time_wins_over_velocity
    # T and V are mutually exclusive; T takes precedence when both given
    out = StackchanBleClient::FrameCodec.encode_head(
      yaw: 200, pitch: nil, time_ms: 1500, velocity: 80
    )
    assert_equal "<Y:200,T:1500>\n", out
  end
end

class FrameCodecAckTest < Test::Unit::TestCase
  def test_ack_ok_byte
    assert_equal :ok, StackchanBleClient::FrameCodec.parse_ack(".")
  end

  def test_ack_error_byte
    assert_equal :error, StackchanBleClient::FrameCodec.parse_ack("?")
  end

  def test_unknown_ack_frame_raises
    assert_raise(ArgumentError) do
      StackchanBleClient::FrameCodec.parse_ack("X")
    end
  end

  def test_parse_ack_accepts_newline_terminated_ok_frame
    assert_equal :ok, StackchanBleClient::FrameCodec.parse_ack(".\n")
  end

  def test_parse_ack_accepts_newline_terminated_error_frame
    assert_equal :error, StackchanBleClient::FrameCodec.parse_ack("?\n")
  end

  def test_parse_ack_rejects_frame_starting_with_unknown_byte
    assert_raise(ArgumentError) { StackchanBleClient::FrameCodec.parse_ack("<Y_actual:0,P_actual:600>\n") }
  end
end
