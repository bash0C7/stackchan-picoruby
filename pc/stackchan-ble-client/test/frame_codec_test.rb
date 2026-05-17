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
    assert_equal "<L:1,R:0,G:0,B:255,S:L,M:b>\n",
                 StackchanBleClient::FrameCodec.encode_led(r: 0, g: 0, b: 255, side: :left, mode: :blink)
  end

  def test_encode_led_right_yellow_breathing
    assert_equal "<L:1,R:255,G:255,B:0,S:R,M:p>\n",
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

class FrameCodecAckTest < Test::Unit::TestCase
  def test_ack_ok_byte
    assert_equal :ok, StackchanBleClient::FrameCodec.parse_ack(".")
  end

  def test_ack_error_byte
    assert_equal :error, StackchanBleClient::FrameCodec.parse_ack("?")
  end

  def test_unknown_ack_byte_raises
    assert_raise(ArgumentError) do
      StackchanBleClient::FrameCodec.parse_ack("X")
    end
  end
end
