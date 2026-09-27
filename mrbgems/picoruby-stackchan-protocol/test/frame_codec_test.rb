class FrameCodecTest < Picotest::Test
  FC = Stackchan::BLE::FrameCodec

  def test_encode_face
    assert_equal "<F:0>\n", FC.encode_face(face_name: :neutral)
    assert_equal "<F:2>\n", FC.encode_face(face_name: :joy)
  end

  def test_encode_led_puts_stackchans_left_on_wire_side_r_and_encodes_the_mode
    assert_equal "<L:1,R:255,G:0,B:0,S:B,M:s>\n",
                 FC.encode_led(r: 255, g: 0, b: 0, side: :both, mode: :solid)
    assert_equal "<L:1,R:0,G:0,B:255,S:R,M:b>\n",
                 FC.encode_led(r: 0, g: 0, b: 255, side: :left, mode: :blink)
    assert_equal "<L:1,R:255,G:255,B:0,S:L,M:p>\n",
                 FC.encode_led(r: 255, g: 255, b: 0, side: :right, mode: :breathing)
  end

  def test_encode_head_time_and_velocity
    assert_equal "<YL:50,PU:30,T:500>\n",
                 FC.encode_head(yaw_left: 50, yaw_right: nil, pitch_up: 30, time_ms: 500, velocity: nil)
    assert_equal "<YR:20,V:80>\n",
                 FC.encode_head(yaw_left: nil, yaw_right: 20, pitch_up: nil, time_ms: nil, velocity: 80)
  end

  def test_encode_misc_frames
    assert_equal "<torque:on>\n",  FC.encode_torque(on: true)
    assert_equal "<torque:off>\n", FC.encode_torque(on: false)
    assert_equal "<selftest:run>\n", FC.encode_selftest
    assert_equal "<read:pos>\n", FC.encode_read_pos
  end

  def test_touch_event_and_zone
    assert_equal true,  FC.touch_event?("<touch:2>\n")
    assert_equal false, FC.touch_event?("<F:0>\n")
    assert_equal 2,   FC.parse_touch("<touch:2>\n")
    assert_nil        FC.parse_touch("<F:0>\n")
  end
end
