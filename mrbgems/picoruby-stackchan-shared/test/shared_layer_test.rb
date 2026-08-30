# Picotest suite for the shared layer. Runs on the host picoruby VM.
# Literal expectations (CRuby-independent); the repro/shared-parity probe is the
# separate CRuby<->PicoRuby cross-check.
class StackchanSharedTest < Picotest::Test
  FC = Stackchan::BLE::FrameCodec
  H  = Stackchan::BLE::HsbToRgb
  FT = Stackchan::AI::FrameText

  def test_encode_face
    assert_equal "<F:0>\n", FC.encode_face(face_name: :neutral)
    assert_equal "<F:2>\n", FC.encode_face(face_name: :joy)
  end

  def test_encode_led_side_reversal_and_mode
    # API :left = StackChan's left hand = wire "R"; :right = wire "L".
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

  def test_parse_ack_and_touch
    assert_equal :ok,    FC.parse_ack(".")
    assert_equal :error, FC.parse_ack("?")
    assert_equal true,  FC.touch_event?("<touch:2>\n")
    assert_equal false, FC.touch_event?("<F:0>\n")
    assert_equal 2,   FC.parse_touch("<touch:2>\n")
    assert_nil        FC.parse_touch("<F:0>\n")
  end

  def test_hsb_to_rgb
    assert_equal [0, 0, 0],     H.convert(0x000000)
    assert_equal [255, 0, 0],   H.convert(0x00FFFF)
    assert_equal [40, 159, 160], H.convert(0x80C0A0)
  end

  def test_send_builder_dedup_and_order
    b = Stackchan::BLE::SendBuilder.new
    b.face(:smile)
    b.led(:rgb, 0x112233, side: :both, mode: :solid)
    b.led(:red, side: :left, mode: :blink)
    b.head(yaw_left: 40, pitch_up: 10, time_ms: 300)
    expected = [
      "<F:1>\n",
      "<L:1,R:17,G:34,B:51,S:B,M:s>\n",
      "<L:1,R:255,G:0,B:0,S:R,M:b>\n",
      "<YL:40,PU:10,T:300>\n",
    ]
    assert_equal expected, b.to_frames
  end

  def test_frame_text_sanitize_and_truncate
    # delimiters neutralized, newline collapsed to a single space
    assert_equal "<F:0,text:a、b＜c＞d e>\n", FT.build(face_index: 0, text: "a,b<c>d\ne")
    assert_equal "<text:今日は、＜良い＞天気 ですね>\n",
                 FT.build(face_index: nil, text: "今日は、<良い>天気\nですね")
    # multibyte truncation to 19 chars
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
