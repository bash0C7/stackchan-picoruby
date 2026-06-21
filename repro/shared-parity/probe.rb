# Pure exercise of the shared layer. Assumes Stackchan::BLE::* and
# Stackchan::AI::* are already loaded. Prints one result line per case so the
# CRuby (pc/stackchan) and PicoRuby (gem) runs can be diffed for parity.
def line(label, value)
  $stdout.write("#{label}\t#{value.inspect}\n")
  $stdout.flush
end

FC = Stackchan::BLE::FrameCodec

line "face_neutral", FC.encode_face(face_name: :neutral)
line "face_joy",     FC.encode_face(face_name: :joy)
line "led_both_red", FC.encode_led(r: 255, g: 0, b: 0, side: :both, mode: :solid)
line "led_left_blue_blink", FC.encode_led(r: 0, g: 0, b: 255, side: :left, mode: :blink)
line "led_off", FC.encode_led(r: 0, g: 0, b: 0, side: :both, mode: :off)
line "head_yl_t", FC.encode_head(yaw_left: 50, yaw_right: nil, pitch_up: 30, time_ms: 500, velocity: nil)
line "head_yr_v", FC.encode_head(yaw_left: nil, yaw_right: 20, pitch_up: nil, time_ms: nil, velocity: 80)
line "torque_on",  FC.encode_torque(on: true)
line "torque_off", FC.encode_torque(on: false)
line "selftest", FC.encode_selftest
line "read_pos", FC.encode_read_pos
line "ack_ok",    FC.parse_ack(".")
line "ack_error", FC.parse_ack("?")
line "touch_event_true",  FC.touch_event?("<touch:2>\n")
line "touch_event_false", FC.touch_event?("<F:0>\n")
line "parse_touch_2",   FC.parse_touch("<touch:2>\n")
line "parse_touch_nil", FC.parse_touch("<F:0>\n")

H = Stackchan::BLE::HsbToRgb
line "hsb_000000", H.convert(0x000000)
line "hsb_red_full", H.convert(0x00FFFF)   # hue 0, full sat, full bright
line "hsb_mid", H.convert(0x80C0A0)
line "hsb_high_hue", H.convert(0xE0FFFF)

SB = Stackchan::BLE::SendBuilder
b = SB.new
b.face(:smile)
b.led(:rgb, 0x112233, side: :both, mode: :solid)
b.led(:red, side: :left, mode: :blink)
b.led(:hsb, 0x00FFFF, side: :right, mode: :breathing)
b.head(yaw_left: 40, pitch_up: 10, time_ms: 300)
b.torque(on: true)
line "builder_frames", b.to_frames

FT = Stackchan::AI::FrameText
line "ft_plain", FT.build(face_index: 2, text: "こんにちは")
line "ft_nil_face", FT.build(face_index: nil, text: "やあ")
line "ft_sanitize", FT.build(face_index: 0, text: "a,b<c>d\ne")
line "ft_truncate", FT.build(face_index: nil, text: "0123456789012345678901234567")
line "ft_truncate_jp", FT.build(face_index: 1, text: "あいうえおかきくけこさしすせそたちつてとなにぬ")
line "ft_mixed_nl", FT.build(face_index: nil, text: "今日は、<良い>天気\nですね")
