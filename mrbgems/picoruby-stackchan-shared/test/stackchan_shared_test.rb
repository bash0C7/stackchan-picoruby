class StackchanSharedTest < Picotest::Test
  FC = Stackchan::BLE::FrameCodec
  FT = Stackchan::AI::FrameText

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

  def test_send_builder_keeps_one_frame_per_key_in_first_occurrence_order
    b = Stackchan::BLE::SendBuilder.new
    b.face(:smile)
    b.led(:green, side: :both, mode: :solid)
    b.led(:red, side: :left, mode: :blink)
    b.head(yaw_left: 40, pitch_up: 10, time_ms: 300)
    expected = [
      "<F:1>\n",
      "<L:1,R:0,G:255,B:0,S:B,M:s>\n",
      "<L:1,R:255,G:0,B:0,S:R,M:b>\n",
      "<YL:40,PU:10,T:300>\n",
    ]
    assert_equal expected, b.to_frames
  end

  def test_send_builder_rewriting_an_earlier_key_keeps_its_first_position
    b = Stackchan::BLE::SendBuilder.new
    b.face(:smile)
    b.led(:blue)
    b.face(:sad)
    assert_equal ["<F:4>\n", "<L:1,R:0,G:0,B:255,S:B,M:s>\n"], b.to_frames
  end

  def test_send_builder_rejects_an_unknown_led_color
    assert_raise(ArgumentError) { Stackchan::BLE::SendBuilder.new.led(:rgb) }
  end

  def test_frame_text_neutralizes_delimiters_and_collapses_newlines_to_one_space
    assert_equal "<F:0,text:a、b＜c＞d e>\n", FT.build(face_index: 0, text: "a,b<c>d\ne")
    assert_equal "<text:今日は、＜良い＞天気 ですね>\n",
                 FT.build(face_index: nil, text: "今日は、<良い>天気\nですね")
  end

  def test_frame_text_truncates_multibyte_text_to_19_chars
    assert_equal "<F:1,text:あいうえおかきくけこさしすせそたちつて>\n",
                 FT.build(face_index: 1, text: "あいうえおかきくけこさしすせそたちつてとなにぬ")
  end

  def test_ble_error_hierarchy
    assert Stackchan::BLE::TimeoutError.ancestors.include?(Stackchan::BLE::Error)
    assert Stackchan::BLE::DeviceError.ancestors.include?(Stackchan::BLE::Error)
    assert Stackchan::BLE::ConnectionError.ancestors.include?(Stackchan::BLE::Error)
    assert Stackchan::BLE::Error.ancestors.include?(StandardError)
  end
end
